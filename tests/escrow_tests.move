#[test_only]
module grainlify_payout::escrow_tests {
    use std::option;
    use std::signer;
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;
    use aptos_framework::timestamp;

    use grainlify_payout::escrow;
    use grainlify_payout::test_asset;
    use grainlify_payout::tree_vectors;

    const EVENT_ID: vector<u8> = b"founding-pool-2026";
    const SWEEP_DEST: address = @0x5EED;
    // Exactly MINIMUM_CLAIM_WINDOW (30 days), so every test that publishes a
    // root also exercises the floor's boundary as an accepted value. Real events
    // use escrow::recommended_claim_window() (24 months) or longer.
    const WINDOW: u64 = 2592000;
    // Genesis-ish start so deadline arithmetic is not near zero.
    const T0: u64 = 1_000_000;

    struct Fixture has drop {
        admin_addr: address,
        escrow_addr: address,
        metadata: Object<Metadata>,
    }

    fun setup(aptos_framework: &signer, admin: &signer, funding: u64): Fixture {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test_secs(T0);

        let admin_addr = signer::address_of(admin);
        let metadata = test_asset::create(admin);

        escrow::initialise(admin, EVENT_ID, metadata, SWEEP_DEST, WINDOW);
        let escrow_addr = escrow::escrow_address(admin_addr, EVENT_ID);

        if (funding > 0) {
            test_asset::mint(admin, admin_addr, funding);
            escrow::fund(admin, escrow_addr, funding);
        };

        Fixture { admin_addr, escrow_addr, metadata }
    }

    fun account_at(addr: address): signer {
        account::create_account_for_test(addr)
    }

    fun id(byte: u8): vector<u8> {
        let out = vector::empty<u8>();
        let i = 0;
        while (i < 32) { vector::push_back(&mut out, byte); i = i + 1; };
        out
    }

    // -----------------------------------------------------------------------
    // Tree vectors
    // -----------------------------------------------------------------------

    // The generator itself, before anything is built from it.
    #[test]
    fun synthetic_leaves_match_the_shared_vector() {
        assert!(tree_vectors::synth_leaf(0) == tree_vectors::sample_0(), 0);
        assert!(tree_vectors::synth_leaf(1) == tree_vectors::sample_1(), 1);
        assert!(tree_vectors::synth_leaf(2) == tree_vectors::sample_2(), 2);
    }

    // The pin: seven roots, computed through this module's own node rule, must
    // equal the digests the Go builder and the Soroban contract both assert.
    #[test]
    fun tree_roots_match_the_pinned_cross_implementation_vectors() {
        assert!(tree_vectors::root_from_digests(tree_vectors::synth_leaves(1)) == tree_vectors::root_1(), 1);
        assert!(tree_vectors::root_from_digests(tree_vectors::synth_leaves(2)) == tree_vectors::root_2(), 2);
        assert!(tree_vectors::root_from_digests(tree_vectors::synth_leaves(3)) == tree_vectors::root_3(), 3);
        assert!(tree_vectors::root_from_digests(tree_vectors::synth_leaves(5)) == tree_vectors::root_5(), 5);
        assert!(tree_vectors::root_from_digests(tree_vectors::synth_leaves(6)) == tree_vectors::root_6(), 6);
        assert!(tree_vectors::root_from_digests(tree_vectors::synth_leaves(7)) == tree_vectors::root_7(), 7);
        assert!(tree_vectors::root_from_digests(tree_vectors::synth_leaves(38)) == tree_vectors::root_38(), 38);
    }

    // The sibling path, not only the final root.
    //
    // Two different paths can fold to the same root, so a root vector alone
    // does not prove the two sides agree on what a claimant actually submits -
    // and the path is the thing that travels between backend and contract.
    #[test]
    fun the_pinned_proof_verifies_through_the_real_verifier() {
        let root = tree_vectors::root_7();
        assert!(
            escrow::verify_proof_for_test(
                &root,
                tree_vectors::proof_leaf(),
                &tree_vectors::proof_siblings(),
            ),
            0,
        );
    }

    // A proof one sibling short must not verify. Guards against a verifier that
    // stops early or ignores trailing steps.
    #[test]
    fun a_truncated_proof_does_not_verify() {
        let root = tree_vectors::root_7();
        let siblings = tree_vectors::proof_siblings();
        let _ = vector::pop_back(&mut siblings);
        assert!(
            !escrow::verify_proof_for_test(&root, tree_vectors::proof_leaf(), &siblings),
            0,
        );
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun funding_credits_the_escrow(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 1_000_000);
        assert!(escrow::balance(f.escrow_addr) == 1_000_000, 0);
        assert!(option::is_none(&escrow::root(f.escrow_addr)), 1);
        assert!(escrow::event_id(f.escrow_addr) == EVENT_ID, 2);
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun publish_root_records_the_root_and_total(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 1_000_000);
        let root = tree_vectors::root_3();
        escrow::publish_root(admin, f.escrow_addr, root, 600_000);

        assert!(option::borrow(&escrow::root(f.escrow_addr)) == &root, 0);
        assert!(escrow::root_total(f.escrow_addr) == 600_000, 1);
    }

    // Write-once, and permanently. A second root would either invalidate proofs
    // already served or silently change what somebody is owed.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 6, location = grainlify_payout::escrow)]
    fun a_root_cannot_be_republished(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 1_000_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 600_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_5(), 100_000);
    }

    // Refused rather than accepted-and-stranded: the last claimants would find
    // nothing left, having been told on-chain they were owed it.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 4, location = grainlify_payout::escrow)]
    fun a_root_larger_than_the_escrow_is_refused(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 500_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 500_001);
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE, stranger = @0xBEEF)]
    #[expected_failure(abort_code = 3, location = grainlify_payout::escrow)]
    fun only_the_admin_may_publish(aptos_framework: &signer, admin: &signer, stranger: &signer) {
        let f = setup(aptos_framework, admin, 1_000_000);
        escrow::publish_root(stranger, f.escrow_addr, tree_vectors::root_3(), 600_000);
    }

    // Funding after publication could only create a surplus no leaf accounts
    // for, and this version has no sweep to retrieve it.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 11, location = grainlify_payout::escrow)]
    fun funding_after_publication_is_refused(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 1_000_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 600_000);
        test_asset::mint(admin, f.admin_addr, 1);
        escrow::fund(admin, f.escrow_addr, 1);
    }

    // -----------------------------------------------------------------------
    // Claims
    // -----------------------------------------------------------------------

    // The end-to-end property, through a three-leaf tree so the winning path
    // crosses a PROMOTED node.
    //
    // Three leaves specifically. A two-leaf tree has a single level and its
    // proof never touches promotion, so a verifier that duplicated the odd node
    // instead of promoting it would pass a two-leaf suite completely.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun a_claim_pays_through_a_promoted_node_in_an_odd_tree(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 600_000);

        let a = account_at(@0xAAA1);
        let b = account_at(@0xBBB2);
        let c = account_at(@0xCCC3);
        let id_a = id(0x0A);
        let id_b = id(0x0B);
        let id_c = id(0x0C);

        let leaf_a = escrow::leaf_for(signer::address_of(&a), id_a, 100_000);
        let leaf_b = escrow::leaf_for(signer::address_of(&b), id_b, 200_000);
        let leaf_c = escrow::leaf_for(signer::address_of(&c), id_c, 300_000);

        let leaves = vector::empty<vector<u8>>();
        vector::push_back(&mut leaves, leaf_a);
        vector::push_back(&mut leaves, leaf_b);
        vector::push_back(&mut leaves, leaf_c);

        let sorted = tree_vectors::sort_digests(leaves);
        let root = tree_vectors::root_from_digests(leaves);
        escrow::publish_root(admin, f.escrow_addr, root, 600_000);

        // The first leaf in sorted order: its path is [s1, promoted s2], so the
        // second fold takes in a node that was never hashed.
        let target = *vector::borrow(&sorted, 0);
        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, *vector::borrow(&sorted, 1));
        vector::push_back(&mut proof, *vector::borrow(&sorted, 2));

        // Resolve which entitlement sorted first without assuming.
        let (claimant, identity, amount) = if (target == leaf_a) {
            (&a, id_a, 100_000u64)
        } else if (target == leaf_b) {
            (&b, id_b, 200_000u64)
        } else {
            (&c, id_c, 300_000u64)
        };

        assert!(!escrow::is_claimed(f.escrow_addr, target), 0);

        escrow::claim(claimant, f.escrow_addr, identity, amount, proof);

        assert!(
            test_asset::balance_of(signer::address_of(claimant), f.metadata) == amount,
            1,
        );
        assert!(escrow::balance(f.escrow_addr) == 600_000 - amount, 2);
        assert!(escrow::is_claimed(f.escrow_addr, target), 3);
    }

    // Claiming twice is refused rather than paying twice.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 8, location = grainlify_payout::escrow)]
    fun a_leaf_cannot_be_claimed_twice(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 300_000);
        let a = account_at(@0xAAA1);
        let b = account_at(@0xBBB2);
        let id_a = id(0x0A);
        let id_b = id(0x0B);

        let leaf_a = escrow::leaf_for(signer::address_of(&a), id_a, 100_000);
        let leaf_b = escrow::leaf_for(signer::address_of(&b), id_b, 200_000);
        let root = escrow::hash_node_for_test(leaf_a, leaf_b);
        escrow::publish_root(admin, f.escrow_addr, root, 300_000);

        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, leaf_b);

        escrow::claim(&a, f.escrow_addr, id_a, 100_000, proof);

        let again = vector::empty<vector<u8>>();
        vector::push_back(&mut again, leaf_b);
        escrow::claim(&a, f.escrow_addr, id_a, 100_000, again);
    }

    // A valid proof presented by a different address must not verify. The
    // claiming address is inside the leaf, so the proof only fits its owner.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 7, location = grainlify_payout::escrow)]
    fun a_proof_cannot_be_replayed_by_another_address(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 300_000);
        let a = account_at(@0xAAA1);
        let b = account_at(@0xBBB2);
        let thief = account_at(@0xDEAD);
        let id_a = id(0x0A);
        let id_b = id(0x0B);

        let leaf_a = escrow::leaf_for(signer::address_of(&a), id_a, 100_000);
        let leaf_b = escrow::leaf_for(signer::address_of(&b), id_b, 200_000);
        let root = escrow::hash_node_for_test(leaf_a, leaf_b);
        escrow::publish_root(admin, f.escrow_addr, root, 300_000);

        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, leaf_b);
        escrow::claim(&thief, f.escrow_addr, id_a, 100_000, proof);
    }

    // Changing the amount changes the leaf, so a proof cannot be reused to
    // claim more than it was built for.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 7, location = grainlify_payout::escrow)]
    fun the_amount_is_bound_into_the_leaf(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 300_000);
        let a = account_at(@0xAAA1);
        let b = account_at(@0xBBB2);
        let id_a = id(0x0A);
        let id_b = id(0x0B);

        let leaf_a = escrow::leaf_for(signer::address_of(&a), id_a, 100_000);
        let leaf_b = escrow::leaf_for(signer::address_of(&b), id_b, 200_000);
        let root = escrow::hash_node_for_test(leaf_a, leaf_b);
        escrow::publish_root(admin, f.escrow_addr, root, 300_000);

        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, leaf_b);
        escrow::claim(&a, f.escrow_addr, id_a, 250_000, proof);
    }

    // An internal node offered as a leaf, with a proof one level short. The
    // node prefix is what makes the two hash domains disjoint and this
    // impossible.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 7, location = grainlify_payout::escrow)]
    fun an_internal_node_cannot_be_claimed_as_a_leaf(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 600_000);
        let a = account_at(@0xAAA1);
        let b = account_at(@0xBBB2);
        let attacker = account_at(@0xDEAD);
        let id_a = id(0x0A);
        let id_b = id(0x0B);

        let leaf_a = escrow::leaf_for(signer::address_of(&a), id_a, 100_000);
        let leaf_b = escrow::leaf_for(signer::address_of(&b), id_b, 200_000);
        let inner = escrow::hash_node_for_test(leaf_a, leaf_b);
        let other = escrow::leaf_for(signer::address_of(&attacker), id(0x0F), 300_000);
        let root = escrow::hash_node_for_test(inner, other);
        escrow::publish_root(admin, f.escrow_addr, root, 600_000);

        // Present `inner` as though it were the attacker's own leaf.
        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, other);
        escrow::claim(&attacker, f.escrow_addr, id(0x0F), 300_000, proof);
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 5, location = grainlify_payout::escrow)]
    fun claiming_before_a_root_is_published_fails(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 300_000);
        let a = account_at(@0xAAA1);
        escrow::claim(&a, f.escrow_addr, id(0x0A), 100_000, vector::empty<vector<u8>>());
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 9, location = grainlify_payout::escrow)]
    fun a_zero_amount_claim_is_refused(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 300_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 300_000);
        let a = account_at(@0xAAA1);
        escrow::claim(&a, f.escrow_addr, id(0x0A), 0, vector::empty<vector<u8>>());
    }

    // The LEAF, pinned across implementations - as distinct from the tree.
    //
    // The digest comes from the backend's production ClaimLeaf.Hash. Go writes
    // uint16(len(addr)) then addr, so passing the 32 raw address bytes emits the
    // Aptos layout through the real builder rather than through a copy of it.
    //
    // The address is raw bytes here and a canonical string on Soroban, because an
    // Aptos address has several valid spellings - 0x1, 0x01, the padded 64-digit
    // form - while a Stellar strkey has exactly one. A leaf that depended on
    // which spelling somebody typed would fail permanently against a root that
    // cannot be corrected.
    //
    // Without this, changing LEAF_PREFIX, POOL_CONTRIBUTOR or the amount's left
    // padding left the whole suite green.
    #[test]
    fun the_leaf_matches_the_pinned_cross_implementation_vector() {
        let got = escrow::leaf_for(
            tree_vectors::aptos_leaf_address(),
            tree_vectors::aptos_leaf_identity(),
            tree_vectors::aptos_leaf_amount(),
        );
        assert!(got == tree_vectors::aptos_leaf(), 0);
    }

    // -----------------------------------------------------------------------
    // What a claim must NOT touch
    // -----------------------------------------------------------------------

    // claim() takes borrow_global_mut, because claimed_total is maintained.
    //
    // That is a real loss. When it held an immutable borrow, the type system
    // guaranteed for free that a claim could not alter the root, the deadline, the
    // sweep destination or anybody else's claimed marker. Now nothing prevents it
    // but the code being right, so the guarantee has to be asserted explicitly
    // rather than left implied by the behaviour tests.
    //
    // Everything a claim is permitted to change: the claimant's balance, the
    // escrow balance, that leaf's marker, and claimed_total. Everything else is
    // snapshotted here and compared afterwards.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun a_claim_changes_nothing_it_has_no_business_changing(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 600_000);

        let a = account_at(@0xAAA1);
        let b = account_at(@0xBBB2);
        let c = account_at(@0xCCC3);
        let id_a = id(0x0A);
        let id_b = id(0x0B);
        let id_c = id(0x0C);

        let leaf_a = escrow::leaf_for(signer::address_of(&a), id_a, 100_000);
        let leaf_b = escrow::leaf_for(signer::address_of(&b), id_b, 200_000);
        let leaf_c = escrow::leaf_for(signer::address_of(&c), id_c, 300_000);

        let leaves = vector::empty<vector<u8>>();
        vector::push_back(&mut leaves, leaf_a);
        vector::push_back(&mut leaves, leaf_b);
        vector::push_back(&mut leaves, leaf_c);
        let sorted = tree_vectors::sort_digests(leaves);
        let root = tree_vectors::root_from_digests(leaves);

        escrow::publish_root(admin, f.escrow_addr, root, 600_000);

        // Snapshot everything a claim has no business altering.
        let root_before = escrow::root(f.escrow_addr);
        let root_total_before = escrow::root_total(f.escrow_addr);
        let deadline_before = escrow::claim_deadline(f.escrow_addr);
        let dest_before = escrow::sweep_dest(f.escrow_addr);
        let window_before = escrow::claim_window(f.escrow_addr);
        let event_id_before = escrow::event_id(f.escrow_addr);

        // Claim the leaf that sorts first, whichever entitlement that turns out
        // to be. Its path crosses the promoted node.
        let target = *vector::borrow(&sorted, 0);
        let proof = vector::empty<vector<u8>>();
        vector::push_back(&mut proof, *vector::borrow(&sorted, 1));
        vector::push_back(&mut proof, *vector::borrow(&sorted, 2));
        let (claimant, identity, amount) = if (target == leaf_a) {
            (&a, id_a, 100_000u64)
        } else if (target == leaf_b) {
            (&b, id_b, 200_000u64)
        } else {
            (&c, id_c, 300_000u64)
        };

        escrow::claim(claimant, f.escrow_addr, identity, amount, proof);

        // The published commitment is untouched.
        assert!(escrow::root(f.escrow_addr) == root_before, 0);
        assert!(escrow::root_total(f.escrow_addr) == root_total_before, 1);

        // The sweep terms are untouched. A claim that could move the deadline or
        // redirect the destination would hand a claimant the admin's only powers.
        assert!(escrow::claim_deadline(f.escrow_addr) == deadline_before, 2);
        assert!(escrow::sweep_dest(f.escrow_addr) == dest_before, 3);
        assert!(escrow::claim_window(f.escrow_addr) == window_before, 4);

        assert!(escrow::event_id(f.escrow_addr) == event_id_before, 5);

        // No OTHER leaf became claimed. This is the one that matters most: a
        // claim marking somebody else's leaf would lock a legitimate claimant out
        // permanently, and the root cannot be republished to fix it.
        let i = 0;
        while (i < 3) {
            let leaf = *vector::borrow(&sorted, i);
            let want_claimed = leaf == target;
            assert!(escrow::is_claimed(f.escrow_addr, leaf) == want_claimed, 6);
            i = i + 1;
        };

        // And only the claimed amount left the escrow.
        assert!(escrow::balance(f.escrow_addr) == 600_000 - amount, 7);
        assert!(escrow::claimed_total(f.escrow_addr) == amount, 8);
    }

    // The same invariant across two claims, because a single claim cannot show
    // that the second one leaves the first one's marker alone.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun a_second_claim_leaves_the_first_ones_marker_alone(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 300_000);
        let a = account_at(@0xAAA1);
        let b = account_at(@0xBBB2);
        let id_a = id(0x0A);
        let id_b = id(0x0B);

        let leaf_a = escrow::leaf_for(signer::address_of(&a), id_a, 100_000);
        let leaf_b = escrow::leaf_for(signer::address_of(&b), id_b, 200_000);
        let root = escrow::hash_node_for_test(leaf_a, leaf_b);
        escrow::publish_root(admin, f.escrow_addr, root, 300_000);
        let deadline_before = escrow::claim_deadline(f.escrow_addr);

        let pa = vector::empty<vector<u8>>();
        vector::push_back(&mut pa, leaf_b);
        escrow::claim(&a, f.escrow_addr, id_a, 100_000, pa);

        let pb = vector::empty<vector<u8>>();
        vector::push_back(&mut pb, leaf_a);
        escrow::claim(&b, f.escrow_addr, id_b, 200_000, pb);

        assert!(escrow::is_claimed(f.escrow_addr, leaf_a), 0);
        assert!(escrow::is_claimed(f.escrow_addr, leaf_b), 1);
        assert!(escrow::claimed_total(f.escrow_addr) == 300_000, 2);
        assert!(escrow::claim_deadline(f.escrow_addr) == deadline_before, 3);
        assert!(escrow::root_total(f.escrow_addr) == 300_000, 4);
    }

    // -----------------------------------------------------------------------
    // Sweeps
    // -----------------------------------------------------------------------

    // Residue is sweepable immediately, and cannot touch what the root promised.
    //
    // The strong form of the assertion: fund ABOVE the root, sweep the residue,
    // then claim every leaf successfully. If sweep_residue ever reached into
    // root_total, the last claim would fail for want of balance.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun sweep_residue_cannot_touch_what_the_root_promised(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 350_000);
        let a = account_at(@0xAAA1);
        let b = account_at(@0xBBB2);
        let id_a = id(0x0A);
        let id_b = id(0x0B);

        let leaf_a = escrow::leaf_for(signer::address_of(&a), id_a, 100_000);
        let leaf_b = escrow::leaf_for(signer::address_of(&b), id_b, 200_000);
        let root = escrow::hash_node_for_test(leaf_a, leaf_b);
        // Funded 350_000 against a root of 300_000: 50_000 is residue.
        escrow::publish_root(admin, f.escrow_addr, root, 300_000);

        escrow::sweep_residue(admin, f.escrow_addr);
        assert!(test_asset::balance_of(SWEEP_DEST, f.metadata) == 50_000, 0);
        assert!(escrow::balance(f.escrow_addr) == 300_000, 1);

        // Both claims still succeed in full.
        let pa = vector::empty<vector<u8>>();
        vector::push_back(&mut pa, leaf_b);
        escrow::claim(&a, f.escrow_addr, id_a, 100_000, pa);

        let pb = vector::empty<vector<u8>>();
        vector::push_back(&mut pb, leaf_a);
        escrow::claim(&b, f.escrow_addr, id_b, 200_000, pb);

        assert!(test_asset::balance_of(signer::address_of(&a), f.metadata) == 100_000, 2);
        assert!(test_asset::balance_of(signer::address_of(&b), f.metadata) == 200_000, 3);
        assert!(escrow::balance(f.escrow_addr) == 0, 4);
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 15, location = grainlify_payout::escrow)]
    fun sweep_residue_with_nothing_spare_is_refused(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 300_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 300_000);
        escrow::sweep_residue(admin, f.escrow_addr);
    }

    // The timelock: one second before the deadline it is refused, at the deadline
    // it succeeds.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 14, location = grainlify_payout::escrow)]
    fun sweeping_unclaimed_before_the_deadline_is_refused(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 300_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 300_000);
        timestamp::update_global_time_for_test_secs(T0 + WINDOW - 1);
        escrow::sweep_unclaimed(admin, f.escrow_addr);
    }

    // And the whole point of the design: the sweep leaves the root and the
    // claimed markers intact, so a late claimant can still prove what they were
    // owed from chain state alone.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun sweeping_unclaimed_leaves_the_evidence_intact(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 300_000);
        let a = account_at(@0xAAA1);
        let b = account_at(@0xBBB2);
        let id_a = id(0x0A);
        let id_b = id(0x0B);

        let leaf_a = escrow::leaf_for(signer::address_of(&a), id_a, 100_000);
        let leaf_b = escrow::leaf_for(signer::address_of(&b), id_b, 200_000);
        let root = escrow::hash_node_for_test(leaf_a, leaf_b);
        escrow::publish_root(admin, f.escrow_addr, root, 300_000);

        // One of the two claims; the other never turns up.
        let pa = vector::empty<vector<u8>>();
        vector::push_back(&mut pa, leaf_b);
        escrow::claim(&a, f.escrow_addr, id_a, 100_000, pa);
        assert!(escrow::claimed_total(f.escrow_addr) == 100_000, 0);

        timestamp::update_global_time_for_test_secs(T0 + WINDOW);
        escrow::sweep_unclaimed(admin, f.escrow_addr);

        assert!(test_asset::balance_of(SWEEP_DEST, f.metadata) == 200_000, 1);
        assert!(escrow::balance(f.escrow_addr) == 0, 2);

        // The evidence a late claimant needs is all still readable.
        assert!(option::borrow(&escrow::root(f.escrow_addr)) == &root, 3);
        assert!(escrow::root_total(f.escrow_addr) == 300_000, 4);
        assert!(escrow::claimed_total(f.escrow_addr) == 100_000, 5);
        assert!(escrow::is_claimed(f.escrow_addr, leaf_a), 6);
        assert!(!escrow::is_claimed(f.escrow_addr, leaf_b), 7);
    }

    // A claimant arriving AFTER the deadline is still paid, so long as nobody has
    // swept. The deadline opens the sweep; it does not close claims.
    //
    // This is the largest mitigation for the late-claimant case, and it is a
    // property of an assertion that is deliberately absent from claim().
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun a_claim_after_the_deadline_still_pays_until_the_sweep(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 300_000);
        let a = account_at(@0xAAA1);
        let b = account_at(@0xBBB2);
        let id_a = id(0x0A);
        let id_b = id(0x0B);

        let leaf_a = escrow::leaf_for(signer::address_of(&a), id_a, 100_000);
        let leaf_b = escrow::leaf_for(signer::address_of(&b), id_b, 200_000);
        let root = escrow::hash_node_for_test(leaf_a, leaf_b);
        escrow::publish_root(admin, f.escrow_addr, root, 300_000);

        // Well past the deadline, and no sweep has happened.
        timestamp::update_global_time_for_test_secs(T0 + WINDOW + 10_000);

        let pa = vector::empty<vector<u8>>();
        vector::push_back(&mut pa, leaf_b);
        escrow::claim(&a, f.escrow_addr, id_a, 100_000, pa);
        assert!(test_asset::balance_of(signer::address_of(&a), f.metadata) == 100_000, 0);
    }

    // Extend-only, from both sides.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun extending_the_deadline_reopens_a_sweep_that_was_legal(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 300_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 300_000);
        assert!(escrow::claim_deadline(f.escrow_addr) == T0 + WINDOW, 0);

        timestamp::update_global_time_for_test_secs(T0 + WINDOW);
        // Sweepable right now. Extending must make it not so.
        escrow::extend_deadline(admin, f.escrow_addr, T0 + WINDOW + 500);
        assert!(escrow::claim_deadline(f.escrow_addr) == T0 + WINDOW + 500, 1);
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 14, location = grainlify_payout::escrow)]
    fun a_sweep_that_was_legal_becomes_illegal_after_an_extension(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 300_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 300_000);
        timestamp::update_global_time_for_test_secs(T0 + WINDOW);
        escrow::extend_deadline(admin, f.escrow_addr, T0 + WINDOW + 500);
        escrow::sweep_unclaimed(admin, f.escrow_addr);
    }

    // The safety property. An earlier deadline is refused, so the admin can never
    // bring a cutoff forward.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 13, location = grainlify_payout::escrow)]
    fun the_deadline_cannot_be_shortened(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 300_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 300_000);
        escrow::extend_deadline(admin, f.escrow_addr, T0 + WINDOW - 1);
    }

    // Equal is not later. Guards the boundary of the comparison.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 13, location = grainlify_payout::escrow)]
    fun the_deadline_cannot_be_set_to_itself(aptos_framework: &signer, admin: &signer) {
        let f = setup(aptos_framework, admin, 300_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 300_000);
        escrow::extend_deadline(admin, f.escrow_addr, T0 + WINDOW);
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE, stranger = @0xBEEF)]
    #[expected_failure(abort_code = 3, location = grainlify_payout::escrow)]
    fun only_the_admin_may_extend(
        aptos_framework: &signer, admin: &signer, stranger: &signer,
    ) {
        let f = setup(aptos_framework, admin, 300_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 300_000);
        escrow::extend_deadline(stranger, f.escrow_addr, T0 + WINDOW + 500);
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE, stranger = @0xBEEF)]
    #[expected_failure(abort_code = 3, location = grainlify_payout::escrow)]
    fun only_the_admin_may_sweep_unclaimed(
        aptos_framework: &signer, admin: &signer, stranger: &signer,
    ) {
        let f = setup(aptos_framework, admin, 300_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 300_000);
        timestamp::update_global_time_for_test_secs(T0 + WINDOW);
        escrow::sweep_unclaimed(stranger, f.escrow_addr);
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 5, location = grainlify_payout::escrow)]
    fun residue_cannot_be_swept_before_a_root_exists(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 300_000);
        // No root, so every token is potentially claimable and none is residue.
        escrow::sweep_residue(admin, f.escrow_addr);
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun the_sweep_destination_and_window_are_readable_from_creation(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 0);
        assert!(escrow::sweep_dest(f.escrow_addr) == SWEEP_DEST, 0);
        assert!(escrow::claim_window(f.escrow_addr) == WINDOW, 1);
        // Zero until a root exists: the clock starts at publication.
        assert!(escrow::claim_deadline(f.escrow_addr) == 0, 2);
    }

    // 24 months, the agreed default.
    #[test]
    fun the_recommended_window_is_twenty_four_months() {
        assert!(escrow::recommended_claim_window() == 730 * 24 * 60 * 60, 0);
    }

    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 12, location = grainlify_payout::escrow)]
    fun a_zero_claim_window_is_refused(aptos_framework: &signer, admin: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let metadata = test_asset::create(admin);
        escrow::initialise(admin, EVENT_ID, metadata, SWEEP_DEST, 0);
    }

    // The mistake the floor exists for: 30 meaning thirty DAYS, passed as thirty
    // seconds. Nothing else in the system would catch it, and it would publish a
    // root that became sweepable almost immediately - no cliff anybody could see,
    // and a sweep that looked entirely legitimate on chain.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 12, location = grainlify_payout::escrow)]
    fun a_seconds_for_days_units_slip_is_refused(
        aptos_framework: &signer, admin: &signer,
    ) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let metadata = test_asset::create(admin);
        escrow::initialise(admin, EVENT_ID, metadata, SWEEP_DEST, 30);
    }

    // One second below the floor, to pin the boundary from the failing side.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    #[expected_failure(abort_code = 12, location = grainlify_payout::escrow)]
    fun a_window_one_second_below_the_floor_is_refused(
        aptos_framework: &signer, admin: &signer,
    ) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let metadata = test_asset::create(admin);
        escrow::initialise(admin, EVENT_ID, metadata, SWEEP_DEST, escrow::minimum_claim_window() - 1);
    }

    // And the floor itself is accepted, so it is a floor and not a threshold one
    // above it. Every other test in this file relies on this, since WINDOW is
    // exactly the floor.
    #[test(aptos_framework = @aptos_framework, admin = @0xA11CE)]
    fun a_window_exactly_at_the_floor_is_accepted(
        aptos_framework: &signer, admin: &signer,
    ) {
        let f = setup(aptos_framework, admin, 0);
        assert!(escrow::claim_window(f.escrow_addr) == escrow::minimum_claim_window(), 0);
    }

    // The floor and the default are separate numbers with separate jobs: a floor
    // can only prevent a catastrophically short window, while the default is the
    // figure to reach for absent a reason.
    #[test]
    fun the_floor_is_thirty_days_and_below_the_default() {
        assert!(escrow::minimum_claim_window() == 30 * 24 * 60 * 60, 0);
        assert!(escrow::minimum_claim_window() < escrow::recommended_claim_window(), 1);
    }

    // The leaf must be deterministic across runs and machines, or a root built
    // today cannot be claimed against tomorrow.
    #[test]
    fun the_leaf_construction_is_deterministic() {
        let once = escrow::leaf_for(@0xAAA1, id(0x11), 1_500_000);
        let twice = escrow::leaf_for(@0xAAA1, id(0x11), 1_500_000);
        assert!(once == twice, 0);
        assert!(vector::length(&once) == 32, 1);

        // A different address is a different leaf.
        assert!(escrow::leaf_for(@0xAAA2, id(0x11), 1_500_000) != once, 2);
        // A different identity is a different leaf.
        assert!(escrow::leaf_for(@0xAAA1, id(0x12), 1_500_000) != once, 3);
    }
}
