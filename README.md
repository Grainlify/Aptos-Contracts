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
| `initialise` | admin | One escrow per `(admin, event_id)`. Fixes the sweep destination and claim window |
| `fund` | anyone | Refused once a root is published |
| `publish_root` | admin | Once per event, permanently. Requires `total == funded_total`. Starts the claim clock |
| `claim` | the claimant | Verifies a proof, marks claimed, then transfers. **No deadline check** |
| `extend_deadline` | admin | Can only move the deadline **later** |
| `sweep_residue` | admin | Returns `balance − root_total` only. No timelock |
| `sweep_unclaimed` | admin | Returns the remainder, after the deadline |
| `is_claimed`, `claim_deadline`, `claimed_total`, `sweep_dest`, `claim_window` | anyone | Views |
| `balance`, `root`, `root_total`, `event_id`, `leaf_for`, `escrow_address` | anyone | Views |

Deliberately **not** in this version: a maintainer pool, commit–reveal for draw
seeds, and any form of cancellation. The first two exist in the Soroban contract
and are the obvious next additions; the third is a design question, not an
omission.

## The sweep

A sweep is an admin moving somebody else's money, which is the thing this
contract otherwise makes impossible. Everything below exists to constrain that.

### Two functions, because there are two pots

A settled escrow holds two amounts with opposite risk profiles, and the Soroban
contract's single `sweep` conflates them. That is the one thing here that is not a
port.

| Pot | Amount | Belongs to | Risk of moving it |
| --- | --- | --- | --- |
| Residue | `balance − root_total` | Nobody — and since `publish_root` requires `total == funded_total`, this can only ever be an unsolicited deposit | None whatsoever |
| Unclaimed | `root_total − claimed_total` | Named individuals who have not turned up | Taking money from a person |

Conflating them makes the safe operation inherit the dangerous one's timelock,
and — worse — normalises the dangerous one by association. “We sweep the escrow
after settlement” sounds routine; “we take unclaimed payouts from 38 named
people” is the same sentence.

So `sweep_residue` has no timelock, because there is no argument for one. Only
`sweep_unclaimed` is constrained.

### What the admin cannot do

| Dimension | Discretion | Constrained by |
| --- | --- | --- |
| Destination | **None** | Fixed at `initialise`, before funding. No parameter exists anywhere |
| Amount | **None** | Residue is arithmetic; unclaimed is whatever nobody took |
| Timing | **One-directional** | `extend_deadline` can only increase the deadline |
| Who is affected | **None** | No per-leaf sweep. All remaining unclaimed, or nothing |

The extend-only rule is the entire safety property. It turns “the admin can cut
people off” into “the admin can only give more time”, so the worst use of it is
delaying their own sweep. **Do not relax it** — it is the kind of constraint
someone removes later for convenience, because the failing call looks like an
obstacle rather than the guarantee.

### The claimant who arrives late

Not solved, and not presented as solved. A deadline that can be enforced is a
deadline somebody can miss. Four things reduce the harm:

1. **The deadline gates the sweep, not the claim.** There is deliberately no
   deadline assertion in `claim`, so a late claimant is paid in full for as long
   as nobody has swept. They are only cut off by a deliberate admin act, not by a
   clock ticking over. This is the largest mitigation and it is a property of what
   is *absent* from `claim` — easy to destroy by adding one plausible assertion.
2. **A long window.** 24 months is the agreed default
   (`recommended_claim_window()`). Idle funds cost the treasury inconvenience; a
   missed claim costs a person their payout. Those are not comparable, so the
   window wants to be the longest anyone will tolerate.
3. **Extension is the documented remedy**, not an exception. The money is still in
   escrow, so extending is a real fix, and it is a public on-chain act.
4. **The sweep leaves the evidence intact.** The root, `root_total`,
   `claimed_total` and every claimed marker survive it, so a late claimant holding
   their proof can demonstrate from chain state alone exactly what they were owed —
   without needing to be believed and without trusting our database.

`SweptUnclaimed` carries the full shortfall (`root_total`, `claimed_total`, amount
taken), so what was removed from people is public record rather than an internal
number.

### Copy for the terms and the claim page — the obvious wording is false

Whoever writes the contributor-facing copy will reach for a deadline sentence, and
the natural one is a lie. Inherit this instead.

**Wrong:**

> Claim your reward by 12 March 2028 or you will lose it.

That is not what the contract does. Nothing expires on that date. A claim
submitted on 13 March pays in full, and so does one submitted a year later, right
up until somebody calls `sweep_unclaimed`. Telling people otherwise frightens them
with a cliff that does not exist — and worse, it teaches anyone who misses the date
that they have already lost, so they never ask, and a claim that would still have
paid goes unmade.

**Right:**

> Your reward has no expiry date. From 12 March 2028 we may return unclaimed
> funds to the Grainlify treasury — and until we actually do, your claim still
> pays in full. If you have missed the date, contact us: while the funds are
> still in escrow we can extend the window for you.

Three things that copy has to carry, and the third is the one usually dropped:

1. **The date is when we *may* sweep**, not when the claim stops working.
2. **Until the sweep happens, the claim pays in full.**
3. **Missing the date is recoverable while the funds remain**, by asking. That is
   `extend_deadline`, and it is a real remedy rather than a courtesy.

And a placement requirement that is not the contract's business but decides
whether any of this matters: **the date has to be in front of the person, not in
the terms.** In the claim page, in the notification that tells them they are owed
something, and again as it approaches. A deadline that only exists in a document
nobody reads is precisely how the missed-claim case happens.

Anyone can verify the date themselves against the chain via `claim_deadline()`,
which is a view for exactly that reason.

### No claim-rate floor

A rule refusing to sweep below some claimed fraction was considered and rejected.
It can permanently trap funds in a way nobody can undo, and it hard-codes a
judgement a person looking at a bad claim rate makes better. The remedy for a low
claim rate is to extend and chase people; the emitted shortfall is what makes that
visible enough to act on.

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

## Operating one

See [RUNBOOK.md](RUNBOOK.md) for the full sequence and, more importantly, for what
each step locks permanently. The short version: `publish_root` is the point of no
return for shortening a claim window, because `extend_deadline` can only move a
deadline later.

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
