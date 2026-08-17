#[test_only]
/// The cross-implementation Merkle tree vectors, as Move constants.
///
/// **These are a copied fixture, and that is deliberate.** The authoritative
/// artefact is `internal/chain/testdata/leaf_vector.json` in the Grainlify
/// backend, and a copy of it sits beside this package at
/// `fixtures/leaf_vector.json`. Move cannot read a file at runtime, so the
/// values have to be literals somewhere; reaching across a repository boundary
/// to fetch them would break this package's ability to be extracted with no
/// edits, which is a harder requirement than avoiding a copy.
///
/// The residual risk is honest and worth naming: a copy can drift. Three things
/// hold it in place.
///
/// 1. The values are **frozen**. They pin a construction that a published root
///    depends on, so changing one is not a refactor, it is invalidating every
///    proof already served. Drift here is a deliberate act, not an accident.
/// 2. The backend has a test that reads *this file* and the JSON fixture beside
///    it and fails if either disagrees with its own vector. It skips cleanly
///    once this package is extracted and the paths no longer resolve.
/// 3. `fixtures/leaf_vector.json` is a byte-for-byte copy, so a human can diff
///    the two repositories without reading Move.
///
/// WHAT THESE PIN.
///
/// The leaf digest was already pinned across implementations. The tree above it
/// was not, so every internal-node rule was free to differ between languages
/// while both suites stayed green. Measured on the Go side: deleting the node
/// prefix, changing it, and reversing the leaf sort all survived as mutations.
///
/// Three rules, all of which move a root here if they move anywhere:
///
///   1. Leaves are sorted ASCENDING by digest before the tree is built.
///   2. An internal node is sha256(0x01 || min(a,b) || max(a,b)).
///   3. An odd node at any level is PROMOTED unchanged, never duplicated.
///      Duplicating is the CVE-2012-2459 shape, where two different leaf sets
///      produce one root.
///
/// WHY THESE LEAF COUNTS.
///
/// Because pairs are sorted inside the node hash, reversing the leaf sort is
/// invisible at power-of-two counts and changes the root at every other count:
///
///   n=2 identical   n=3 DIFFERENT   n=4 identical   n=5 DIFFERENT
///   n=6 DIFFERENT   n=7 DIFFERENT   n=8 identical
///
/// So 3, 5, 6 and 7 are the counts that can catch it, 1 and 2 anchor the
/// degenerate cases, and 38 is the real founding contributor pool size - the
/// first tree intended for publication, and not a power of two.
module grainlify_payout::tree_vectors {
    use std::vector;

    use grainlify_payout::escrow;

    /// `leaf_i = sha256(0xFF || uint16_be(i))`
    ///
    /// Synthetic, so the tree vectors pin the tree rule alone and stay valid on
    /// any chain whatever its address encoding. `0xFF` is neither the leaf
    /// prefix (0x00) nor the node prefix (0x01), so a synthetic digest can never
    /// collide with a real leaf.
    public fun synth_leaf(i: u16): vector<u8> {
        let buf = vector::empty<u8>();
        vector::push_back(&mut buf, 0xFFu8);
        vector::push_back(&mut buf, (((i >> 8) & 0xFF) as u8));
        vector::push_back(&mut buf, ((i & 0xFF) as u8));
        std::hash::sha2_256(buf)
    }

    /// `n` synthetic digests in generator order, deliberately NOT sorted.
    /// Sorting is one of the rules under test.
    public fun synth_leaves(n: u16): vector<vector<u8>> {
        let out = vector::empty<vector<u8>>();
        let i = 0u16;
        while (i < n) {
            vector::push_back(&mut out, synth_leaf(i));
            i = i + 1;
        };
        out
    }

    /// Build a root from leaf digests, using the escrow module's own node rule.
    ///
    /// It calls `escrow::hash_node_for_test` rather than reimplementing the node
    /// hash. That is the whole point: a vector asserted through a local copy of
    /// the rule pins the copy, and lets the copy and the real verifier drift -
    /// which is the failure the vectors exist to catch.
    public fun root_from_digests(digests: vector<vector<u8>>): vector<u8> {
        let level = sort_digests(digests);
        while (vector::length(&level) > 1) {
            let next = vector::empty<vector<u8>>();
            let i = 0;
            let n = vector::length(&level);
            while (i < n) {
                if (i + 1 == n) {
                    // Promote, never duplicate.
                    vector::push_back(&mut next, *vector::borrow(&level, i));
                    i = i + 1;
                } else {
                    vector::push_back(
                        &mut next,
                        escrow::hash_node_for_test(
                            *vector::borrow(&level, i),
                            *vector::borrow(&level, i + 1),
                        ),
                    );
                    i = i + 2;
                }
            };
            level = next;
        };
        *vector::borrow(&level, 0)
    }

    /// Insertion sort, ascending by digest. Small n, and clarity beats speed in
    /// a fixture.
    public fun sort_digests(input: vector<vector<u8>>): vector<vector<u8>> {
        let out = vector::empty<vector<u8>>();
        let n = vector::length(&input);
        let i = 0;
        while (i < n) {
            let candidate = *vector::borrow(&input, i);
            let pos = 0;
            let m = vector::length(&out);
            while (pos < m && lt_bytes(vector::borrow(&out, pos), &candidate)) {
                pos = pos + 1;
            };
            vector::insert(&mut out, pos, candidate);
            i = i + 1;
        };
        out
    }

    fun lt_bytes(a: &vector<u8>, b: &vector<u8>): bool {
        let n = vector::length(a);
        let i = 0;
        while (i < n) {
            let x = *vector::borrow(a, i);
            let y = *vector::borrow(b, i);
            if (x < y) { return true };
            if (x > y) { return false };
            i = i + 1;
        };
        false
    }

    // -----------------------------------------------------------------------
    // The pinned values
    // -----------------------------------------------------------------------
    //
    // Byte-for-byte identical to tree_vectors.roots in
    // internal/chain/testdata/leaf_vector.json and to the copy in
    // fixtures/leaf_vector.json.
    //
    // If an assertion against these fails, one implementation moved. Fix the
    // side that moved; do not edit the vector to make it pass. A published root
    // cannot be corrected, so a vector edited to match a changed builder is a
    // claim nobody can make.

    public fun root_1(): vector<u8> { x"7fa54a42524916a1648ec76ce75d295024840b7a3a4f4bbaf3e43155d0014767" }
    public fun root_2(): vector<u8> { x"f5c9186b3b65e6ce5e21dbc239099cca42e0a33498441279117df13a37dcbac2" }
    public fun root_3(): vector<u8> { x"ee89867ea8655639197d33339b404961ea36d5bbb6a0dba2f1149a8c7dc1eddc" }
    public fun root_5(): vector<u8> { x"70f49ea377797a1ce9e8e065d5e77024393a2109a8b6c8caf51c4a1b975242b3" }
    public fun root_6(): vector<u8> { x"d882a0abe524b3f68d10aa4da5e199b9284258b523abae598568fdfff89bdc43" }
    public fun root_7(): vector<u8> { x"73f9296cbe6d89bc6edb6ae7a8ec0cf4633c80bbe390da0fb0ea4291ac7427c5" }
    public fun root_38(): vector<u8> { x"7b4e1ecf8567f90c1fad1bdfac40a72fdb1444205b258994b65aa80078bcd093" }

    /// The three generator samples, which anchor `synth_leaf` itself. Without
    /// them a divergence in the generator surfaces as every root being wrong,
    /// which reads as a tree bug and sends the reader to the wrong file.
    public fun sample_0(): vector<u8> { x"7fa54a42524916a1648ec76ce75d295024840b7a3a4f4bbaf3e43155d0014767" }
    public fun sample_1(): vector<u8> { x"942e1e2a66a427b6551732f758bc314f22b9cdec9365a3425c9184de299392b5" }
    public fun sample_2(): vector<u8> { x"81b27ac11ee1954f52f091e776eb7922b027228412419357f8b6499172e511f7" }

    // -----------------------------------------------------------------------
    // The Aptos leaf vector
    // -----------------------------------------------------------------------
    //
    // The leaf, as distinct from the tree. Generated by the backend's production
    // ClaimLeaf.Hash - not by a second implementation written to match it - and
    // recorded in aptos_leaf_vector in the shared JSON.
    //
    // Three mutations survived the Move suite before this existed: the leaf
    // prefix, the pool byte, and the amount's left padding could each be changed
    // with every test still passing. The suite asserted that leaves were
    // deterministic and that different inputs differed, and any
    // consistent-but-wrong construction satisfies both.

    public fun aptos_leaf_address(): address {
        @0x1111111111111111111111111111111111111111111111111111111111111111
    }

    public fun aptos_leaf_identity(): vector<u8> {
        x"2222222222222222222222222222222222222222222222222222222222222222"
    }

    public fun aptos_leaf_amount(): u64 { 1500000 }

    public fun aptos_leaf(): vector<u8> {
        x"0e27ca98933aaace053a59d4082f803453e2ced8579a8b6598994dcc77b435d4"
    }

    /// The pinned proof: the first leaf in sorted order of the n=7 tree, and its
    /// sibling path. n=7 is the deepest odd tree here, so this path crosses a
    /// promoted node.
    public fun proof_leaf(): vector<u8> { x"1b7c6b7486b0559e068e54906ee5960c41264830702b91a88fe6beaddd4066b7" }

    public fun proof_siblings(): vector<vector<u8>> {
        let out = vector::empty<vector<u8>>();
        vector::push_back(&mut out, x"492f5673d343de79b87dfb93f76f6e1819b1390524f1164278cbe64f018d5a8b");
        vector::push_back(&mut out, x"9ab233784c48eddc51e5b228976cdd4dbbcc13a9bc9b562739acdfccbd8be341");
        vector::push_back(&mut out, x"f943342e6480525be2e44eebd4f096a7c6a3799d02b2162645654bd054637963");
        out
    }
}
