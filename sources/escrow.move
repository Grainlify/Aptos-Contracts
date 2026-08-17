/// Grainlify payout escrow: one event's budget, one Merkle claim root, pull
/// claims only.
///
/// Companion to the Soroban `GrainhackEscrow`, and a deliberate port of it
/// rather than a fresh design - the arguments were had once already and are
/// recorded there. Two rules govern every decision in this file:
///
/// **The chain never decides anything.** Judging, eligibility and the payout
/// arithmetic stay off-chain and authoritative. This module holds funds and
/// honours a root the backend published. It cannot compute an allocation, so it
/// can never disagree with one.
///
/// **Claims are pull-based.** Grainlify publishes a root; contributors claim
/// against it and pay their own gas. Nothing is ever pushed to a list of
/// addresses: a failed push mid-loop leaves an event half-paid with no clean
/// recovery, and pushing requires holding everyone's address at once. There is
/// no function here that moves money to an address the caller did not sign for.
module grainlify_payout::escrow {
    use std::bcs;
    use std::hash;
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;

    use aptos_std::table::{Self, Table};

    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleStore, Metadata};
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    // -----------------------------------------------------------------------
    // Domain separation
    // -----------------------------------------------------------------------

    /// Prefix byte for a Merkle **leaf** hash.
    ///
    /// Second-preimage resistance. Without distinct prefixes for leaves and
    /// internal nodes, a crafted internal node can be presented as a leaf: an
    /// attacker who knows two sibling leaves can hash them, submit that digest
    /// as though it were a leaf, and claim against a proof one level short. The
    /// prefix makes the two hash domains disjoint.
    const LEAF_PREFIX: u8 = 0x00;

    /// Prefix byte for an internal node hash.
    const NODE_PREFIX: u8 = 0x01;

    /// The pool byte inside the leaf.
    ///
    /// The canonical leaf construction carries a pool discriminator so a
    /// contributor leaf is structurally unable to verify against a maintainer
    /// root. This version implements the contributor pool only, so the byte is
    /// fixed at 0 - a maintainer leaf therefore hashes differently and can
    /// never be claimed here, which is the correct behaviour for a module that
    /// does not hold a maintainer budget.
    ///
    /// Adding the second pool later does not change the leaf format, only which
    /// value is passed: the byte is already in the digest. It does mean a root
    /// and a balance per pool, held under separate keys, exactly as the Soroban
    /// version does.
    const POOL_CONTRIBUTOR: u8 = 0x00;

    /// Every digest in this construction is 32 bytes: sha256 output, and the
    /// Aptos address width.
    const DIGEST_LEN: u64 = 32;

    /// The agreed default claim window: 24 months in seconds.
    ///
    /// Not enforced - `initialise` takes the window as an argument, because an
    /// event whose contributors are individually known and can be chased should
    /// use a far longer one. This is the figure to reach for absent a reason.
    ///
    /// The asymmetry behind it is not close. Funds sitting unswept cost the
    /// treasury some inconvenience; a claim missed to a deadline costs a person
    /// their payout. Those are not comparable magnitudes, so the window wants to
    /// be the longest anybody will tolerate rather than the shortest that looks
    /// tidy.
    const RECOMMENDED_CLAIM_WINDOW: u64 = 63072000;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    const E_ALREADY_INITIALISED: u64 = 1;
    const E_NOT_INITIALISED: u64 = 2;
    const E_NOT_ADMIN: u64 = 3;
    const E_INSUFFICIENT_ESCROW: u64 = 4;
    const E_ROOT_NOT_PUBLISHED: u64 = 5;
    const E_ROOT_ALREADY_PUBLISHED: u64 = 6;
    const E_INVALID_PROOF: u64 = 7;
    const E_ALREADY_CLAIMED: u64 = 8;
    const E_INVALID_AMOUNT: u64 = 9;
    const E_BAD_DIGEST_LENGTH: u64 = 10;
    /// Funding after publication could only create a surplus the published root
    /// does not account for, so it is refused rather than silently accepted.
    const E_ALREADY_SETTLED: u64 = 11;
    /// A zero claim window would make every claim late the instant a root is
    /// published.
    const E_INVALID_WINDOW: u64 = 12;
    /// The deadline may only ever move later. See `extend_deadline`.
    const E_DEADLINE_NOT_LATER: u64 = 13;
    /// Claims are still open, so unclaimed funds are not sweepable yet.
    const E_CLAIM_WINDOW_OPEN: u64 = 14;
    /// Nothing to sweep.
    const E_NO_RESIDUE: u64 = 15;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    /// One escrow per event, held in its own object.
    ///
    /// **One object per event is load-bearing, not tidiness.** The canonical
    /// leaf deliberately omits any event identifier, on the grounds that one
    /// escrow is one event and the root a proof verifies against lives inside
    /// it, so a leaf has nowhere else to be replayed. A single shared module
    /// holding many events' roots would break that in two ways at once: the
    /// same entitlement in two events would produce the *same* leaf digest, so
    /// one claimed marker would block a second legitimate claim, and one
    /// event's claims could draw on another's balance. Separate objects make
    /// both structurally impossible instead of a keying discipline someone has
    /// to remember.
    struct Escrow has key {
        /// Recorded so a reconciler can confirm which event an object is,
        /// rather than inferring it from the address it derived.
        event_id: vector<u8>,
        admin: address,
        metadata: Object<Metadata>,
        /// The escrow's own store. Funds live here, never in an account.
        store: Object<FungibleStore>,
        /// Generates the object's signer, which is what authorises a withdrawal
        /// from `store`. Held by the object, so no account can spend the escrow.
        extend_ref: ExtendRef,
        /// `none` until published, so "never published" and "published" are
        /// distinguishable - a reconciler needs that difference.
        root: Option<vector<u8>>,
        /// What the root commits to in total. Asserted against the balance at
        /// publication.
        root_total: u64,
        /// Claimed markers keyed by leaf digest. A table rather than a vector
        /// so claim cost does not grow with the number of claimants.
        claimed: Table<vector<u8>, bool>,
        /// Running sum of everything claimed.
        ///
        /// Maintained rather than derived, because a table's values cannot be
        /// totalled on-chain. It is what makes the shortfall at sweep time a
        /// published number instead of something reconstructed afterwards from
        /// events.
        claimed_total: u64,
        /// Where a sweep sends funds. **Fixed here at creation and never
        /// changeable.**
        ///
        /// Fixed at initialisation rather than at publication, which is earlier
        /// than it strictly needs to be and deliberately so: the guarantee worth
        /// having is that a contributor can see where unclaimed money goes
        /// before they have any reason to care. Initialisation precedes funding,
        /// which precedes publication, so this is public before a single token
        /// enters the contract.
        ///
        /// If this address is ever lost, the sweep becomes permanently unusable
        /// and the funds stay in escrow. That is the correct direction to fail,
        /// and is why there is no path to change it.
        sweep_dest: address,
        /// How long after publication claims remain open, in seconds. Set here
        /// so it is knowable before anybody commits work.
        claim_window: u64,
        /// The absolute deadline, computed at publication.
        ///
        /// Zero until a root is published. The clock starts when claims become
        /// *possible*, not when the escrow was created - an escrow can sit
        /// unfunded for months and that must not eat into anyone's window.
        claim_deadline: u64,
    }

    #[event]
    struct EscrowCreated has drop, store {
        escrow: address,
        event_id: vector<u8>,
        admin: address,
        /// Emitted so the destination is on the record from creation, not first
        /// visible when somebody sweeps.
        sweep_dest: address,
        claim_window: u64,
    }

    #[event]
    struct Funded has drop, store {
        escrow: address,
        from: address,
        amount: u64,
        balance: u64,
    }

    #[event]
    struct RootPublished has drop, store {
        escrow: address,
        root: vector<u8>,
        total: u64,
        /// The deadline and destination are echoed here because publication is
        /// the moment claims become real, and both are things a claimant needs
        /// to be able to read without trusting anything we say off-chain.
        claim_deadline: u64,
        sweep_dest: address,
    }

    #[event]
    struct DeadlineExtended has drop, store {
        escrow: address,
        old_deadline: u64,
        new_deadline: u64,
    }

    #[event]
    struct SweptResidue has drop, store {
        escrow: address,
        amount: u64,
        dest: address,
    }

    #[event]
    /// Emitted when unclaimed entitlements are swept.
    ///
    /// Carries the shortfall in full - what the root promised, what was actually
    /// claimed, and what was taken - so the size of what was removed from named
    /// people is a matter of public record rather than an internal number. A
    /// successor escrow for late claimants is computable from this alone.
    struct SweptUnclaimed has drop, store {
        escrow: address,
        amount: u64,
        root_total: u64,
        claimed_total: u64,
        dest: address,
    }

    #[event]
    /// Emitted on a successful claim.
    ///
    /// The **leaf digest is included**, which the Soroban version does not do -
    /// it emits claimant and amount. The reconciler stores leaves, so keying
    /// its reconciliation on the leaf means it never has to re-derive one from
    /// an address and an amount to find out whether a row settled.
    struct Claimed has drop, store {
        escrow: address,
        claimant: address,
        amount: u64,
        leaf: vector<u8>,
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    #[view]
    /// Derive an event's escrow address without creating anything.
    ///
    /// Deterministic from (admin, event_id), so the backend can compute where
    /// an escrow will live before it exists and record it in `chain_operations`
    /// before submitting - which is what makes crash recovery able to ask "did
    /// this happen?" by effect rather than by transaction hash.
    public fun escrow_address(admin: address, event_id: vector<u8>): address {
        object::create_object_address(&admin, event_seed(event_id))
    }

    fun event_seed(event_id: vector<u8>): vector<u8> {
        let seed = b"grainlify_payout::escrow::v1::";
        vector::append(&mut seed, event_id);
        seed
    }

    /// Create an event's escrow. One per (admin, event_id).
    ///
    /// `sweep_dest` and `claim_window` are both fixed here, before funding and
    /// before publication, so that everything about what happens to unclaimed
    /// money is public before there is any money to be unclaimed.
    ///
    /// On the window: 24 months is the agreed default (`RECOMMENDED_CLAIM_WINDOW`).
    /// The asymmetry driving that is not close - idle funds cost the treasury
    /// some inconvenience, while a missed claim costs a person their payout - so
    /// the window should be the longest anyone will tolerate rather than the
    /// shortest that seems tidy. For an event whose contributors are individually
    /// known and can simply be chased, a window of years is the right answer, and
    /// means the sweep exists and is tested without ever being reached.
    public entry fun initialise(
        admin: &signer,
        event_id: vector<u8>,
        metadata: Object<Metadata>,
        sweep_dest: address,
        claim_window: u64,
    ) {
        let admin_addr = signer::address_of(admin);
        assert!(
            !exists<Escrow>(escrow_address(admin_addr, event_id)),
            E_ALREADY_INITIALISED,
        );
        // A zero window would make every claim late the instant a root is
        // published, which is the one configuration that turns this contract
        // into a way of not paying people.
        assert!(claim_window > 0, E_INVALID_WINDOW);

        let ctor = object::create_named_object(admin, event_seed(event_id));
        let obj_signer = object::generate_signer(&ctor);
        let extend_ref = object::generate_extend_ref(&ctor);
        let store = fungible_asset::create_store(&ctor, metadata);

        move_to(&obj_signer, Escrow {
            event_id,
            admin: admin_addr,
            metadata,
            store,
            extend_ref,
            root: option::none<vector<u8>>(),
            root_total: 0,
            claimed: table::new<vector<u8>, bool>(),
            claimed_total: 0,
            sweep_dest,
            claim_window,
            claim_deadline: 0,
        });

        event::emit(EscrowCreated {
            escrow: signer::address_of(&obj_signer),
            event_id,
            admin: admin_addr,
            sweep_dest,
            claim_window,
        });
    }

    /// Move budget into escrow. Anyone may fund; only a claim takes money out.
    ///
    /// Refused once a root is published: the root asserts `total <= balance` at
    /// publication, so a later top-up could only create a surplus that no leaf
    /// accounts for. `sweep_residue` exists to retrieve exactly that surplus,
    /// but a top-up after publication is still refused - it is far more likely to
    /// be a mistake than an intention, and there is no reason to accept money
    /// that provably cannot be claimed.
    public entry fun fund(
        sponsor: &signer,
        escrow_addr: address,
        amount: u64,
    ) acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        assert!(amount > 0, E_INVALID_AMOUNT);

        let escrow = borrow_global<Escrow>(escrow_addr);
        assert!(option::is_none(&escrow.root), E_ALREADY_SETTLED);

        let from = primary_fungible_store::ensure_primary_store_exists(
            signer::address_of(sponsor),
            escrow.metadata,
        );

        // dispatchable_*, never the plain fungible_asset entrypoint. The
        // dispatchable API is the superset: it honours any withdraw/deposit
        // hooks the issuer registered, and falls through to the default
        // behaviour for assets that have none. USDC on Aptos is a dispatchable
        // fungible asset, so `fungible_asset::transfer` would abort on every
        // real transfer while passing every test against a plain test token.
        dispatchable_fungible_asset::transfer(sponsor, from, escrow.store, amount);

        event::emit(Funded {
            escrow: escrow_addr,
            from: signer::address_of(sponsor),
            amount,
            balance: fungible_asset::balance(escrow.store),
        });
    }

    /// Publish the event's claim root. Admin only, once, permanently.
    ///
    /// Write-once is the whole guarantee. A published root is what contributors
    /// claim against; a second one would either invalidate proofs already
    /// served or silently change what somebody is owed, and an on-chain root
    /// cannot be quietly corrected. The correction path is a new escrow that
    /// supersedes this one, never a mutation of this one.
    ///
    /// The escrow must already hold what the root promises. Publishing a root
    /// larger than the balance would mean the last claimants find nothing left,
    /// having been told on-chain that they were owed it.
    public entry fun publish_root(
        admin: &signer,
        escrow_addr: address,
        root: vector<u8>,
        total: u64,
    ) acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        assert!(vector::length(&root) == DIGEST_LEN, E_BAD_DIGEST_LENGTH);
        assert!(total > 0, E_INVALID_AMOUNT);

        let escrow = borrow_global_mut<Escrow>(escrow_addr);
        assert!(signer::address_of(admin) == escrow.admin, E_NOT_ADMIN);
        assert!(option::is_none(&escrow.root), E_ROOT_ALREADY_PUBLISHED);
        assert!(total <= fungible_asset::balance(escrow.store), E_INSUFFICIENT_ESCROW);

        escrow.root = option::some(root);
        escrow.root_total = total;

        // The clock starts here, not at initialisation. An escrow can sit
        // unfunded for months and none of that time should count against a
        // contributor's window to claim.
        escrow.claim_deadline = timestamp::now_seconds() + escrow.claim_window;

        event::emit(RootPublished {
            escrow: escrow_addr,
            root,
            total,
            claim_deadline: escrow.claim_deadline,
            sweep_dest: escrow.sweep_dest,
        });
    }

    /// Push the claim deadline further out. **It can only ever move later.**
    ///
    /// THIS ONE-DIRECTIONALITY IS THE ENTIRE SAFETY PROPERTY OF THE SWEEP. DO NOT
    /// RELAX IT.
    ///
    /// A sweep is an admin moving somebody else's money, which is the thing this
    /// contract otherwise makes impossible. What makes it tolerable is that every
    /// power the admin holds over the deadline points in the claimant's favour:
    /// they may grant more time, and they may never take time away. So the worst
    /// an admin can do with this function is delay their own sweep.
    ///
    /// Allowing a decrease - even "only before anyone has claimed", even "only for
    /// operational reasons" - converts this from "the admin can give people more
    /// time" into "the admin can cut people off", and those are different
    /// contracts. It is exactly the kind of constraint somebody removes later for
    /// convenience, because the failing call looks like an obstacle rather than
    /// the guarantee.
    ///
    /// This is also the documented remedy for a late claimant: their money is
    /// still in escrow, so extending is a real fix rather than a gesture, and the
    /// extension is a public on-chain act anybody can audit.
    public entry fun extend_deadline(
        admin: &signer,
        escrow_addr: address,
        new_deadline: u64,
    ) acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);

        let escrow = borrow_global_mut<Escrow>(escrow_addr);
        assert!(signer::address_of(admin) == escrow.admin, E_NOT_ADMIN);
        assert!(option::is_some(&escrow.root), E_ROOT_NOT_PUBLISHED);
        assert!(new_deadline > escrow.claim_deadline, E_DEADLINE_NOT_LATER);

        let old_deadline = escrow.claim_deadline;
        escrow.claim_deadline = new_deadline;

        event::emit(DeadlineExtended {
            escrow: escrow_addr,
            old_deadline,
            new_deadline,
        });
    }

    /// Claim against the published root.
    ///
    /// The contributor submits this themselves and pays their own gas, so their
    /// address reaches the chain only by their own action. The leaf commits to a
    /// salted hash of their identity beside the address, never the identity
    /// itself, so the chain never carries a github-login-to-address mapping.
    ///
    /// Ordering is the security property: verify the proof, check the claimed
    /// marker, **set** the claimed marker, then transfer. Setting before the
    /// external call is what makes reentrancy uninteresting.
    ///
    /// **There is deliberately no deadline check here.** `claim_deadline` gates
    /// the sweep, not the claim - it is the moment unclaimed funds *become
    /// sweepable*, not the moment a contributor stops being owed.
    ///
    /// So a claimant arriving after the deadline is still paid in full, for as
    /// long as nobody has swept. They are only ever cut off by the sweep actually
    /// happening, which is a deliberate admin act rather than a clock ticking
    /// over. Adding a deadline check here would move the cliff earlier and buy
    /// nothing: the funds are sitting in escrow with that person's name on them.
    ///
    /// This is the single largest mitigation for the late-claimant case, and it
    /// is a property of what is *absent* from this function, so it is easy to
    /// destroy by adding one plausible-looking assertion.
    public entry fun claim(
        claimant: &signer,
        escrow_addr: address,
        identity_hash: vector<u8>,
        amount: u64,
        proof: vector<vector<u8>>,
    ) acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        assert!(amount > 0, E_INVALID_AMOUNT);
        assert!(vector::length(&identity_hash) == DIGEST_LEN, E_BAD_DIGEST_LENGTH);

        let claimant_addr = signer::address_of(claimant);
        let escrow = borrow_global_mut<Escrow>(escrow_addr);
        assert!(option::is_some(&escrow.root), E_ROOT_NOT_PUBLISHED);

        // The leaf binds the identity hash, the claiming address and the amount
        // together. Binding the address is what stops a valid proof being
        // replayed by somebody else: the leaf only verifies for the address it
        // was built for.
        let leaf = leaf_hash(claimant_addr, identity_hash, amount);

        assert!(!table::contains(&escrow.claimed, leaf), E_ALREADY_CLAIMED);
        assert!(
            verify_proof(option::borrow(&escrow.root), leaf, &proof),
            E_INVALID_PROOF,
        );
        assert!(amount <= fungible_asset::balance(escrow.store), E_INSUFFICIENT_ESCROW);

        // Mark before transferring.
        table::add(&mut escrow.claimed, leaf, true);
        escrow.claimed_total = escrow.claimed_total + amount;

        let escrow_signer = object::generate_signer_for_extending(&escrow.extend_ref);
        let to = primary_fungible_store::ensure_primary_store_exists(
            claimant_addr,
            escrow.metadata,
        );
        let fa = dispatchable_fungible_asset::withdraw(&escrow_signer, escrow.store, amount);
        dispatchable_fungible_asset::deposit(to, fa);

        event::emit(Claimed {
            escrow: escrow_addr,
            claimant: claimant_addr,
            amount,
            leaf,
        });
    }

    // -----------------------------------------------------------------------
    // Sweeps
    // -----------------------------------------------------------------------
    //
    // TWO FUNCTIONS, NOT ONE, AND THE SPLIT IS THE POINT.
    //
    // A settled escrow holds two pots of money with opposite risk profiles:
    //
    //   residue    = balance - root_total
    //                Belongs to nobody. No leaf can claim it, so moving it
    //                cannot harm any claimant under any circumstances.
    //
    //   unclaimed  = root_total - claimed_total
    //                Belongs to named individuals who have not turned up.
    //                Moving it takes money from a person.
    //
    // The Soroban contract has a single `sweep` that takes the whole balance, so
    // these are one operation there. That is the mistake not being ported. It
    // makes the completely safe operation inherit the dangerous one's timelock,
    // and - worse - it normalises the dangerous one by association: "we sweep the
    // escrow after settlement" sounds routine, and "we take unclaimed payouts
    // from 38 named people" is the same sentence.

    /// Return the surplus that no leaf can claim. No timelock.
    ///
    /// `balance - root_total` is provably unclaimable: the root commits to
    /// `root_total` and nothing else, so no proof exists for a single unit above
    /// it. There is therefore no argument for making anybody wait, and no way for
    /// this to disadvantage a claimant.
    ///
    /// This is the ordinary operational case - somebody funded 3,000 and the tree
    /// totalled 2,999.87 - and keeping it separate means that case never reaches
    /// for the mechanism that can dispossess a contributor.
    public entry fun sweep_residue(admin: &signer, escrow_addr: address) acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);

        let escrow = borrow_global<Escrow>(escrow_addr);
        assert!(signer::address_of(admin) == escrow.admin, E_NOT_ADMIN);
        // Before publication there is no root_total, so every token in the
        // escrow is potentially claimable and none of it is residue.
        assert!(option::is_some(&escrow.root), E_ROOT_NOT_PUBLISHED);

        let balance = fungible_asset::balance(escrow.store);
        assert!(balance > escrow.root_total, E_NO_RESIDUE);
        let amount = balance - escrow.root_total;

        transfer_out(escrow, amount);

        event::emit(SweptResidue {
            escrow: escrow_addr,
            amount,
            dest: escrow.sweep_dest,
        });
    }

    /// Return what nobody claimed, once the deadline has passed.
    ///
    /// This is the function that takes money from identified people, and every
    /// constraint on it exists for that reason:
    ///
    /// * The destination was fixed at initialisation, before funding. There is no
    ///   parameter, so the admin has no say in it at the moment of calling.
    /// * The deadline was fixed at publication and can only ever have been moved
    ///   *later*, so the admin cannot bring a cutoff forward.
    /// * The amount is whatever remains. There is no per-leaf sweep, so nobody
    ///   can be singled out.
    ///
    /// **The root and the claimed markers are left intact**, which matters more
    /// than it looks. After a sweep, `is_claimed` still answers correctly and
    /// `root` is still readable, so a late claimant holding their proof can
    /// demonstrate from chain state alone exactly what they were owed - without
    /// needing to be believed, and without trusting our database. That is what
    /// makes any off-chain remedy possible at all.
    ///
    /// There is deliberately **no claim-rate floor**. A rule refusing to sweep
    /// below some fraction was considered and rejected: it can permanently trap
    /// funds in a way nobody can undo, and it hard-codes a judgement that a person
    /// looking at a bad claim rate can make better. The remedy for a low claim
    /// rate is to extend the deadline and chase people, which the emitted
    /// shortfall below makes visible enough to act on.
    public entry fun sweep_unclaimed(admin: &signer, escrow_addr: address) acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);

        let escrow = borrow_global<Escrow>(escrow_addr);
        assert!(signer::address_of(admin) == escrow.admin, E_NOT_ADMIN);
        assert!(option::is_some(&escrow.root), E_ROOT_NOT_PUBLISHED);
        assert!(timestamp::now_seconds() >= escrow.claim_deadline, E_CLAIM_WINDOW_OPEN);

        let amount = fungible_asset::balance(escrow.store);
        assert!(amount > 0, E_NO_RESIDUE);

        transfer_out(escrow, amount);

        event::emit(SweptUnclaimed {
            escrow: escrow_addr,
            amount,
            root_total: escrow.root_total,
            claimed_total: escrow.claimed_total,
            dest: escrow.sweep_dest,
        });
    }

    /// Move funds out of the escrow store to the fixed destination.
    ///
    /// Takes no destination argument, and is private, so there is exactly one
    /// address any sweep can ever pay: the one recorded at initialisation.
    fun transfer_out(escrow: &Escrow, amount: u64) {
        let escrow_signer = object::generate_signer_for_extending(&escrow.extend_ref);
        let to = primary_fungible_store::ensure_primary_store_exists(
            escrow.sweep_dest,
            escrow.metadata,
        );
        let fa = dispatchable_fungible_asset::withdraw(&escrow_signer, escrow.store, amount);
        dispatchable_fungible_asset::deposit(to, fa);
    }

    // -----------------------------------------------------------------------
    // Reads
    // -----------------------------------------------------------------------

    #[view]
    /// Whether a leaf has been claimed.
    ///
    /// Public so the reconciler can compare chain state against its own rows
    /// **without inference**. The chain is the system of record; a reconciler
    /// that had to deduce settlement from an absence would be guessing.
    public fun is_claimed(escrow_addr: address, leaf: vector<u8>): bool acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        let escrow = borrow_global<Escrow>(escrow_addr);
        table::contains(&escrow.claimed, leaf)
    }

    #[view]
    public fun balance(escrow_addr: address): u64 acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        fungible_asset::balance(borrow_global<Escrow>(escrow_addr).store)
    }

    #[view]
    public fun root(escrow_addr: address): Option<vector<u8>> acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        borrow_global<Escrow>(escrow_addr).root
    }

    #[view]
    public fun root_total(escrow_addr: address): u64 acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        borrow_global<Escrow>(escrow_addr).root_total
    }

    #[view]
    public fun event_id(escrow_addr: address): vector<u8> acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        borrow_global<Escrow>(escrow_addr).event_id
    }

    #[view]
    /// When unclaimed funds become sweepable. Zero before publication.
    ///
    /// A view rather than event-only, so the claim page can show an absolute date
    /// and a contributor can verify it against the chain themselves instead of
    /// taking our word for it. If somebody can lose a real payout to a date, that
    /// date has to be readable by them.
    public fun claim_deadline(escrow_addr: address): u64 acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        borrow_global<Escrow>(escrow_addr).claim_deadline
    }

    #[view]
    /// Everything claimed so far. With `root_total`, this is the live shortfall -
    /// the number to look at before deciding whether to sweep or to extend.
    public fun claimed_total(escrow_addr: address): u64 acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        borrow_global<Escrow>(escrow_addr).claimed_total
    }

    #[view]
    /// Where a sweep would send funds. Readable from creation, so it can be
    /// checked before anybody commits work rather than discovered afterwards.
    public fun sweep_dest(escrow_addr: address): address acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        borrow_global<Escrow>(escrow_addr).sweep_dest
    }

    #[view]
    public fun claim_window(escrow_addr: address): u64 acquires Escrow {
        assert!(exists<Escrow>(escrow_addr), E_NOT_INITIALISED);
        borrow_global<Escrow>(escrow_addr).claim_window
    }

    #[view]
    /// The agreed 24-month default, exposed so a deployer can pass it without
    /// transcribing a number of seconds.
    public fun recommended_claim_window(): u64 {
        RECOMMENDED_CLAIM_WINDOW
    }

    #[view]
    /// The leaf digest for a claim, exposed so the backend's Merkle builder can
    /// be tested against this module rather than against a second
    /// implementation of the same rules that can drift.
    public fun leaf_for(claimant: address, identity_hash: vector<u8>, amount: u64): vector<u8> {
        assert!(vector::length(&identity_hash) == DIGEST_LEN, E_BAD_DIGEST_LENGTH);
        leaf_hash(claimant, identity_hash, amount)
    }

    // -----------------------------------------------------------------------
    // Merkle
    // -----------------------------------------------------------------------

    /// `leaf = sha256(0x00 || pool || len(address) || address || identity_hash || amount_be32)`
    ///
    /// The canonical construction, identical in field order and encoding to the
    /// backend's `ClaimLeaf.Hash` and the Soroban contract's `leaf_hash`.
    ///
    /// **The address is the 32 raw bytes, not a string.** This is the one field
    /// that differs from the Soroban version, and it differs because Soroban's
    /// strkey has exactly one valid spelling while an Aptos address does not:
    /// `0x1`, `0x01` and the 64-digit padded form all denote the same account.
    /// Hashing a string here would make the leaf digest depend on how the
    /// address happened to be written when it was registered, and a claim
    /// against a mis-spelled leaf fails permanently against a root that cannot
    /// be corrected. Hashing the raw bytes makes the ambiguity unreachable
    /// rather than a normalisation rule somebody has to remember - and it is
    /// what a signer already holds, so nothing has to canonicalise on-chain.
    ///
    /// The length prefix stays at its true value of 32. Without a length prefix
    /// the boundary between concatenated variable-width fields is not
    /// recoverable and distinct entitlements can collide; the shared
    /// construction requires it whatever the field's width.
    fun leaf_hash(claimant: address, identity_hash: vector<u8>, amount: u64): vector<u8> {
        let buf = vector::empty<u8>();
        vector::push_back(&mut buf, LEAF_PREFIX);
        vector::push_back(&mut buf, POOL_CONTRIBUTOR);

        // Address length as a big-endian u16: 32 == 0x0020.
        vector::push_back(&mut buf, 0u8);
        vector::push_back(&mut buf, (DIGEST_LEN as u8));

        let addr_bytes = bcs::to_bytes(&claimant);
        assert!(vector::length(&addr_bytes) == DIGEST_LEN, E_BAD_DIGEST_LENGTH);
        vector::append(&mut buf, addr_bytes);

        vector::append(&mut buf, identity_hash);
        vector::append(&mut buf, amount_be32(amount));

        hash::sha2_256(buf)
    }

    /// An amount as 32-byte big-endian, right-aligned.
    ///
    /// Fixed width so "10" and "10.0" cannot differ, and 32 bytes so no chain
    /// narrows what another can express. A `u64` here right-aligns into the same
    /// 32-byte field that Soroban fills from an `i128`, so the same magnitude
    /// produces the same bytes on both chains - which is what lets one leaf
    /// construction serve both.
    fun amount_be32(amount: u64): vector<u8> {
        let out = vector::empty<u8>();
        let pad = 0;
        while (pad < 24) {
            vector::push_back(&mut out, 0u8);
            pad = pad + 1;
        };
        let i = 8u8;
        while (i > 0) {
            i = i - 1;
            vector::push_back(&mut out, (((amount >> (i * 8)) & 0xFF) as u8));
        };
        out
    }

    /// Lexicographic byte comparison, `true` when `a <= b`.
    fun le_bytes(a: &vector<u8>, b: &vector<u8>): bool {
        let len_a = vector::length(a);
        let len_b = vector::length(b);
        let n = if (len_a < len_b) { len_a } else { len_b };
        let i = 0;
        while (i < n) {
            let x = *vector::borrow(a, i);
            let y = *vector::borrow(b, i);
            if (x < y) { return true };
            if (x > y) { return false };
            i = i + 1;
        };
        len_a <= len_b
    }

    /// `node = sha256(0x01 || min(a,b) || max(a,b))`
    ///
    /// Sorting the pair removes the need to transmit left/right position with
    /// each proof step. The node prefix is what keeps that safe: without it,
    /// sorted pairs plus an undifferentiated hash let an internal node
    /// masquerade as a leaf.
    fun hash_node(a: vector<u8>, b: vector<u8>): vector<u8> {
        let buf = vector::empty<u8>();
        vector::push_back(&mut buf, NODE_PREFIX);
        if (le_bytes(&a, &b)) {
            vector::append(&mut buf, a);
            vector::append(&mut buf, b);
        } else {
            vector::append(&mut buf, b);
            vector::append(&mut buf, a);
        };
        hash::sha2_256(buf)
    }

    /// Fold a proof into a root.
    fun verify_proof(
        root: &vector<u8>,
        leaf: vector<u8>,
        proof: &vector<vector<u8>>,
    ): bool {
        let computed = leaf;
        let i = 0;
        let n = vector::length(proof);
        while (i < n) {
            computed = hash_node(computed, *vector::borrow(proof, i));
            i = i + 1;
        };
        &computed == root
    }

    // -----------------------------------------------------------------------
    // Test-only exposure
    // -----------------------------------------------------------------------

    #[test_only]
    /// The node rule, for the cross-implementation tree vectors.
    ///
    /// Exposed rather than reimplemented in the test module. The Soroban
    /// contract's suite has a `node()` helper that duplicates its verifier's
    /// logic, which means a root vector asserted through that helper pins the
    /// helper and lets the helper and the real verifier drift apart - the exact
    /// failure the vectors exist to catch, one level up. Exporting the real
    /// function under `#[test_only]` avoids reproducing that here.
    public fun hash_node_for_test(a: vector<u8>, b: vector<u8>): vector<u8> {
        hash_node(a, b)
    }

    #[test_only]
    public fun verify_proof_for_test(
        root: &vector<u8>,
        leaf: vector<u8>,
        proof: &vector<vector<u8>>,
    ): bool {
        verify_proof(root, leaf, proof)
    }
}
