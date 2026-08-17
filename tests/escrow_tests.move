#[test_only]
module grainlify_payout::escrow_tests {
    use std::option;
    use std::signer;
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;

    use grainlify_payout::escrow;
    use grainlify_payout::test_asset;
    use grainlify_payout::tree_vectors;

    const EVENT_ID: vector<u8> = b"founding-pool-2026";

    struct Fixture has drop {
        admin_addr: address,
        escrow_addr: address,
        metadata: Object<Metadata>,
    }

    fun setup(admin: &signer, funding: u64): Fixture {
        let admin_addr = signer::address_of(admin);
        let metadata = test_asset::create(admin);

        escrow::initialise(admin, EVENT_ID, metadata);
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

    #[test(admin = @0xA11CE)]
    fun funding_credits_the_escrow(admin: &signer) {
        let f = setup(admin, 1_000_000);
        assert!(escrow::balance(f.escrow_addr) == 1_000_000, 0);
        assert!(option::is_none(&escrow::root(f.escrow_addr)), 1);
        assert!(escrow::event_id(f.escrow_addr) == EVENT_ID, 2);
    }

    #[test(admin = @0xA11CE)]
    fun publish_root_records_the_root_and_total(admin: &signer) {
        let f = setup(admin, 1_000_000);
        let root = tree_vectors::root_3();
        escrow::publish_root(admin, f.escrow_addr, root, 600_000);

        assert!(option::borrow(&escrow::root(f.escrow_addr)) == &root, 0);
        assert!(escrow::root_total(f.escrow_addr) == 600_000, 1);
    }

    // Write-once, and permanently. A second root would either invalidate proofs
    // already served or silently change what somebody is owed.
    #[test(admin = @0xA11CE)]
    #[expected_failure(abort_code = 6, location = grainlify_payout::escrow)]
    fun a_root_cannot_be_republished(admin: &signer) {
        let f = setup(admin, 1_000_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 600_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_5(), 100_000);
    }

    // Refused rather than accepted-and-stranded: the last claimants would find
    // nothing left, having been told on-chain they were owed it.
    #[test(admin = @0xA11CE)]
    #[expected_failure(abort_code = 4, location = grainlify_payout::escrow)]
    fun a_root_larger_than_the_escrow_is_refused(admin: &signer) {
        let f = setup(admin, 500_000);
        escrow::publish_root(admin, f.escrow_addr, tree_vectors::root_3(), 500_001);
    }

    #[test(admin = @0xA11CE, stranger = @0xBEEF)]
    #[expected_failure(abort_code = 3, location = grainlify_payout::escrow)]
    fun only_the_admin_may_publish(admin: &signer, stranger: &signer) {
        let f = setup(admin, 1_000_000);
        escrow::publish_root(stranger, f.escrow_addr, tree_vectors::root_3(), 600_000);
    }

    // Funding after publication could only create a surplus no leaf accounts
    // for, and this version has no sweep to retrieve it.
    #[test(admin = @0xA11CE)]
    #[expected_failure(abort_code = 11, location = grainlify_payout::escrow)]
    fun funding_after_publication_is_refused(admin: &signer) {
        let f = setup(admin, 1_000_000);
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
    #[test(admin = @0xA11CE)]
    fun a_claim_pays_through_a_promoted_node_in_an_odd_tree(admin: &signer) {
        let f = setup(admin, 600_000);

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
    #[test(admin = @0xA11CE)]
    #[expected_failure(abort_code = 8, location = grainlify_payout::escrow)]
    fun a_leaf_cannot_be_claimed_twice(admin: &signer) {
        let f = setup(admin, 300_000);
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
    #[test(admin = @0xA11CE)]
    #[expected_failure(abort_code = 7, location = grainlify_payout::escrow)]
    fun a_proof_cannot_be_replayed_by_another_address(admin: &signer) {
        let f = setup(admin, 300_000);
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
    #[test(admin = @0xA11CE)]
    #[expected_failure(abort_code = 7, location = grainlify_payout::escrow)]
    fun the_amount_is_bound_into_the_leaf(admin: &signer) {
        let f = setup(admin, 300_000);
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
    #[test(admin = @0xA11CE)]
    #[expected_failure(abort_code = 7, location = grainlify_payout::escrow)]
    fun an_internal_node_cannot_be_claimed_as_a_leaf(admin: &signer) {
        let f = setup(admin, 600_000);
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

    #[test(admin = @0xA11CE)]
    #[expected_failure(abort_code = 5, location = grainlify_payout::escrow)]
    fun claiming_before_a_root_is_published_fails(admin: &signer) {
        let f = setup(admin, 300_000);
        let a = account_at(@0xAAA1);
        escrow::claim(&a, f.escrow_addr, id(0x0A), 100_000, vector::empty<vector<u8>>());
    }

    #[test(admin = @0xA11CE)]
    #[expected_failure(abort_code = 9, location = grainlify_payout::escrow)]
    fun a_zero_amount_claim_is_refused(admin: &signer) {
        let f = setup(admin, 300_000);
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
