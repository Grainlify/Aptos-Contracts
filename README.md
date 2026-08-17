# Grainlify payout escrow — Aptos / Move

One event's budget, one Merkle claim root, pull claims only.

Nothing here has been deployed to any network. No payout has ever been made by
Grainlify on any chain.

## What this is

A port of the Soroban `GrainhackEscrow` (see the `Stellar-Contracts` repository),
not a fresh design. The arguments about domain separation, write-once roots,
mark-before-transfer and pull-only claims were had once already and are recorded
in that contract's source; this module follows them so the two chains cannot
disagree about what a leaf means.

Two rules govern every decision in `sources/escrow.move`:

**The chain never decides anything.** Judging, eligibility and the payout
arithmetic stay off-chain and authoritative. This module holds funds and honours
a root the backend published. It cannot compute an allocation, so it can never
disagree with one.

**Claims are pull-based.** Grainlify publishes a root; contributors claim against
it and pay their own gas. There is no function here that moves money to an
address the caller did not sign for — no batch transfer, no admin-initiated
payout. A failed push mid-loop leaves an event half-paid with no clean recovery,
and pushing requires holding everyone's address at once.

## Surface

| Function | Caller | Notes |
| --- | --- | --- |
| `initialise` | admin | One escrow per `(admin, event_id)`, at a deterministic address |
| `fund` | anyone | Refused once a root is published |
| `publish_root` | admin | Once per event, permanently. Refuses `total > balance` |
| `claim` | the claimant | Verifies a proof, marks claimed, then transfers |
| `is_claimed` | anyone | View, for the reconciler |
| `balance`, `root`, `root_total`, `event_id`, `leaf_for`, `escrow_address` | anyone | Views |

Deliberately **not** in this version: a maintainer pool, a timelocked sweep,
commit–reveal for draw seeds, and any form of cancellation. The first three exist
in the Soroban contract and are the obvious next additions; the fourth is a
design question, not an omission.

Because there is no sweep, **funds committed to a root that nobody claims are
currently unrecoverable.** That is acceptable for a testnet rehearsal and is a
blocker for anything else.

## Two things a reader should know before changing anything

### One escrow object per event is load-bearing

The canonical leaf deliberately omits any event identifier, because one escrow
is one event and the root a proof verifies against lives inside it — so a leaf
has nowhere else to be replayed.

A single shared module holding many events' roots would break that in two ways at
once. The same entitlement in two events produces the *same* leaf digest, so one
claimed marker would block a second legitimate claim; and one event's claims
could draw on another's balance. Separate objects make both structurally
impossible rather than a keying discipline someone has to remember.

If you ever key roots by event inside one shared resource, the event id has to go
back into the leaf — and that changes the digest on every chain.

### The address is hashed as 32 raw bytes, not as a string

This is the one field that differs from the Soroban construction, and it differs
for a reason that only applies here. A Stellar strkey has exactly one valid
spelling. An Aptos address does not: `0x1`, `0x01` and the full 64-digit padded
form all denote the same account.

Hashing a string would make the leaf digest depend on how the address happened to
be written when it was registered, and a claim against a mis-spelled leaf fails
permanently against a root that cannot be corrected. Hashing the raw bytes makes
the ambiguity unreachable instead of a normalisation rule somebody has to
remember.

## The fungible asset API

Every transfer goes through `dispatchable_fungible_asset`, never
`fungible_asset`.

USDC on Aptos is a *dispatchable* fungible asset: the issuer registers custom
withdraw/deposit hooks, which is how a deny-list is implemented. The plain
`fungible_asset::transfer` **aborts** on an asset with registered hooks. The
dispatchable API is the superset — it honours hooks where they exist and falls
through to the default behaviour where they do not.

So a contract written against the plain API would pass every test against a
hookless test token and then abort on every single real claim. Do not "simplify"
these calls.

The tests mint their own hookless asset, which means they prove the calls are
well-formed and prove nothing about hook interaction. A deny-listed claimant or a
paused asset is a testnet rehearsal concern.

## Building and testing

Requires the Aptos CLI.

```sh
aptos move compile --dev
aptos move test --dev
```

`--dev` supplies the `[dev-addresses]` entry for `grainlify_payout`. For a real
deployment, pass the address explicitly:

```sh
aptos move publish --named-addresses grainlify_payout=<address>
```

## The vectors, and why they are copied

`tests/tree_vectors.move` holds the cross-implementation Merkle vectors as Move
literals, and `fixtures/leaf_vector.json` is a byte-for-byte copy of the
authoritative artefact.

**The authoritative artefact is `internal/chain/testdata/leaf_vector.json` in the
Grainlify backend.** Move cannot read a file at runtime, so the values have to be
literals somewhere, and reaching into another repository to fetch them is exactly
what this one must not do.

What holds the copy in place:

1. The values are **frozen**. They pin a construction a published root depends
   on, so changing one is not a refactor, it is invalidating every proof already
   served.
2. **Each implementation asserts the digests independently.** This is the real
   guard, and it works wherever the suites run: Go, Rust and Move each compute
   the same roots from the same rule, so a divergence turns one of the three red.
3. The JSON copy is byte-identical, so the repositories can be diffed without
   reading Move.

The backend's two drift tests are a fourth, weaker layer — see *Related
repositories* below for why they are a convenience rather than a gate.

### What the vectors pin

The leaf digest and the tree above it, which are separate problems.

Roots are pinned at leaf counts **1, 2, 3, 5, 6, 7 and 38**. The odd counts are
not arbitrary: because sibling pairs are sorted inside the node hash, reversing
the leaf sort is invisible at power-of-two counts and changes the root at every
other count.

```
n=2 identical   n=3 DIFFERENT   n=4 identical   n=5 DIFFERENT
n=6 DIFFERENT   n=7 DIFFERENT   n=8 identical
```

38 is the real founding contributor pool size — the first tree intended for
publication, and not a power of two.

`a_claim_pays_through_a_promoted_node_in_an_odd_tree` uses three real leaves
rather than two, because a two-leaf tree has a single level and its proof never
touches promotion. A verifier that duplicated the odd node instead of promoting
it would pass a two-leaf suite completely.

### If a vector assertion fails

One implementation moved. **Fix the side that moved; do not edit the vector to
make it pass.** A published root cannot be corrected, so a vector edited to match
a changed builder is a claim nobody can make.

## Self-containment

This is its own repository and depends on nothing outside it. `aptos move test`
passes with the directory copied anywhere on disk, including outside any git
repository — checked rather than asserted.

Keep it that way. If a change would require a path reaching out of this
repository, that change is wrong: the Merkle vectors come in as fixtures, never
as an import.

## Related repositories

| Repository | Relationship |
| --- | --- |
| `Grainlify-Backend` | Builds the roots this contract honours. Owns the authoritative `internal/chain/testdata/leaf_vector.json`. |
| `Stellar-Contracts` | The Soroban `GrainhackEscrow` this module is a port of. Asserts the same tree vectors. |

The backend has two drift checks — `TestAptosFixture_IsAByteForByteCopy` and
`TestAptosMoveLiterals_MatchTheVector` — that read this repository's fixture and
Move literals when it happens to be checked out as a sibling directory.

**They skip when it is not, which includes CI.** They shorten the feedback loop
on a developer machine; they are not a merge gate. What actually pins the three
implementations to each other is the vectors themselves: each side asserts the
same digests independently, so a divergence turns one of the suites red wherever
it runs.
