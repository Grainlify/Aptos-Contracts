# Operating a payout escrow, start to finish

Written from the code, not from the design. Every gate below is one the contract
actually enforces, and every error named is one it really aborts with.

**Nothing has been deployed to any network.** No step here has executed against
real value. Do the first one on testnet, with one leaf and an address you control.

---

## What is irreversible, and when

Read this before anything else. The contract has four one-way doors, and they
close in this order.

| Step | What it locks, permanently |
| --- | --- |
| `initialise` | The **sweep destination** and the **claim window**. Neither can ever be changed. |
| `fund` | Nothing — but funds cannot be withdrawn until a root exists. |
| `publish_root` | The **root**, the **total**, and the **earliest possible deadline**. |
| `sweep_unclaimed` | Takes unclaimed funds. The affected claimants cannot be paid from this escrow again. |

### `publish_root` is the point of no return for shortening a window

This is the one that will catch somebody out.

Until you publish, the claim window is just a number in a resource and no deadline
exists — but you also cannot change it, because there is no setter. Your only
remedy for a wrong window before publication is to **use a different
`event_id`**, which creates a fresh escrow, and move the funds by claiming
nothing and sweeping the residue.

After publication, `extend_deadline` exists and can only ever move the deadline
**later**. So:

- **A window that is too long** costs you inconvenience. Money sits in escrow for
  longer than you intended and you sweep it later than you would have liked.
- **A window that is too short** costs a contributor their payout, and you cannot
  take it back — you can only push the deadline out, which helps, but you cannot
  undo a sweep that has already happened.

Those are not comparable, which is why the contract only permits correction in one
direction. **Choose the window as though you cannot change it, because in the
direction that matters you cannot.**

`initialise` refuses anything below 30 days (`E_WINDOW_TOO_SHORT`). That floor
exists for a units slip — `30` meaning thirty days — and it is the only wrong
window the contract can catch for you. Any value above 30 days is your judgement
and it will be accepted silently.

The agreed default is **24 months** (`recommended_claim_window()`). For an event
whose contributors are individually known and can simply be chased, use years: the
sweep then exists and is tested without ever being reached.

---

## Phase 0 — Before you touch the chain

Four things that are not the contract's business and will ruin the run if they are
missing.

1. **The dry run has been read by a human.** The allocation comes from
   `founding.DryRun`, which writes nothing. Read the output. It is the only gate
   between an arithmetic mistake and a permanent root.
2. **Every eligible contributor has an address**, or you have decided
   consciously to publish without them. Someone omitted from a root cannot be
   added — the root is write-once. Get the list of eligible-but-address-less
   contributors and look at it.

   Their money must **not** be funded into this escrow. See Phase 2: an omitted
   contributor's share is indistinguishable from residue, and residue has no
   timelock.
3. **The salt exists and is stored.** Leaves commit to
   `sha256(github_login || salt)`.

   Two things to understand about holding it, stated plainly because neither is
   obvious from the code:

   - **Keeping it means we retain the ability to link any leaf back to a GitHub
     login.** That is a capability, not only a secret — it is what lets us answer
     "was this leaf really mine?" for a contributor who asks, and it is what a
     future leak would hand to somebody else.
   - **Destroying it is what makes that link unrecoverable, by anyone including
     us.** Once the claim leaves are stored, proofs no longer need the salt, so
     destruction costs nothing operationally and forecloses the question
     permanently in both directions.

   The decision is per event and belongs after a successful settlement, not
   before one. For the first event the salt is **kept**: it is a rehearsal, and
   retaining the ability to recompute is worth more than the marginal privacy of
   an event that has already been published.

   Losing it is not symmetric with leaking it. Before publication, regenerate and
   carry on. After publication, loss is survivable **only because the leaves are
   stored** — proofs still work, and what is gone is the link back to logins.
4. **The sweep destination address exists and you control it.** It is fixed at
   `initialise` and there is no path to change it. If it is wrong, the sweep is
   permanently unusable.

---

## Phase 1 — `initialise`

```
initialise(admin, event_id, metadata, sweep_dest, claim_window)
```

`metadata` is the fungible asset's metadata object address. On Aptos mainnet USDC
is a **dispatchable** fungible asset; every transfer in this module goes through
`dispatchable_fungible_asset` for that reason. If you point it at a plain test
token the calls still work — the dispatchable API is the superset — so a green
test run does **not** prove hook interaction works. Check that on testnet against
the real asset.

The escrow's address is deterministic: `escrow_address(admin, event_id)`. Compute
it and record it **before** submitting, so a crash between writing your row and
submitting the transaction can be resolved by asking the chain whether the escrow
exists, rather than by hunting for a transaction hash.

**Aborts:** `E_ALREADY_INITIALISED` if that `(admin, event_id)` already has an
escrow; `E_WINDOW_TOO_SHORT` below 30 days.

---

## Phase 2 — `fund`

```
fund(sponsor, escrow_addr, amount)
```

Anyone may fund. Amounts are minor units — 6 decimals for USDC, so 3,000 USDC is
`3_000_000_000`.

**Fund exactly the tree total — not the pool total, and not more.**

**The contract enforces this**, so it is not something you have to remember:
`publish_root` aborts with `E_ROOT_TOTAL_NOT_FUNDED` unless `total` equals what
was funded, and the abort names both figures. What follows is the explanation,
not the protection.

Funding less means it aborts, which is loud and harmless. Funding *more* is the
direction that used to be dangerous, and the reason is not obvious:

> `sweep_residue` returns `balance − root_total` with **no timelock**, on the
> grounds that no leaf can claim it and so it belongs to nobody. That is only
> true if the tree contains every person entitled to a share.

An eligible contributor who has not registered an address **cannot be in the
tree**, but the settlement still computed an amount for them. If you fund the
full pool, that person's money sits in the escrow looking exactly like residue —
sweepable immediately, with no deadline and no notice. The one protection the
design gives an absent claimant, the claim window, does not apply to it.

So the money for contributors without addresses stays in the treasury, earmarked
off-chain, and never enters this escrow.

One consequence worth knowing, because it makes `sweep_residue` safer than it was
designed to be: since the root must equal what was funded, **our own funding can
no longer produce a surplus at all**. Residue is now, by construction, only ever
money somebody deposited into the store without going through `fund` — so it can
never contain a contributor's share.

The check compares against what was funded rather than the store balance, because
`dispatchable_fungible_asset::deposit` takes no signer: anybody can push tokens
into the escrow's store. Comparing against the balance would let one unsolicited
unit block publication permanently.

**Aborts:** `E_ALREADY_SETTLED` once a root is published. Top-ups after
publication are refused, because they could only create a surplus no leaf accounts
for.

---

## Phase 3 — `publish_root`

```
publish_root(admin, escrow_addr, root, total)
```

Assert before you call it, off-chain:

- The tree was built from `Result.PayableLines()` — strictly positive amounts
  only. A zero-amount leaf is permanently unclaimable and commits "this person
  got nothing" to a root that cannot be edited.
- `total` equals the sum of leaf amounts exactly. `founding.DryRun` asserts the
  lines sum to the pool; assert the leaf total matches what you are about to
  publish.
- The leaf count is what you expect. For the founding pool that is 38, and 38 is
  not a power of two — which is exactly the range where a tree-construction bug is
  visible. The vectors cover it.

**Aborts:** `E_ROOT_ALREADY_PUBLISHED` on a second attempt — permanently, for that
escrow. `E_INSUFFICIENT_ESCROW` if `total > balance`. `E_NOT_ADMIN`.

On success the deadline is set to `now + claim_window` and appears in
`RootPublished` alongside the destination. Read it back with `claim_deadline()`
and put that date in front of contributors — see the copy guidance in the README,
because the obvious wording is wrong.

---

## Phase 4 — Claims

Contributors call `claim` themselves and pay their own gas. Nothing to operate.

Two things worth knowing while you wait:

- **The deadline does not stop claims.** It is when unclaimed funds *become
  sweepable*. A claim after the deadline pays in full for as long as nobody has
  swept.
- `claimed_total()` against `root_total()` is the live shortfall. This is the
  number to watch.

---

## Phase 5 — `sweep_residue`

```
sweep_residue(admin, escrow_addr)
```

Returns `balance - root_total`, the amount no leaf can claim. No timelock, because
there is no argument for one — this cannot affect any claimant.

Safe to call as soon as the root is published. **Aborts:** `E_NO_RESIDUE` when
there is no surplus; `E_ROOT_NOT_PUBLISHED` before publication, since without a
root every token is potentially claimable.

---

## Phase 6 — The sweep decision

After the deadline you have two options and the contract deliberately does not
choose for you.

**Look at the claim rate first.**

```
claimed_total() / root_total()
```

A low rate almost never means contributors declined their money. It means they
never heard about it. A notification failure and a genuine forfeiture look
identical on chain.

- **Rate looks reasonable** → `sweep_unclaimed(admin, escrow_addr)`.
- **Rate looks bad** → `extend_deadline(admin, escrow_addr, later)` and go and
  find people. The money is still in escrow; extending is a real remedy.

There is no claim-rate floor in the contract. One was considered and rejected: it
can permanently trap funds in a way nobody can undo, and it hard-codes a judgement
you make better with the numbers in front of you. **This decision is yours by
design — do not automate it.**

`sweep_unclaimed` leaves the root, `root_total`, `claimed_total` and every claimed
marker intact, so a late claimant holding their proof can still demonstrate from
chain state exactly what they were owed. `SweptUnclaimed` records the full
shortfall.

**Aborts:** `E_CLAIM_WINDOW_OPEN` before the deadline; `E_NO_RESIDUE` if the
escrow is already empty; `E_NOT_ADMIN`.

---

## If something looks wrong

| Symptom | Cause | Remedy |
| --- | --- | --- |
| `publish_root` aborts 16 | `total` is not what was funded | Compare the two figures the abort names. Funding the pool total where the leaf total was meant is the usual cause. |
| `publish_root` aborts 4 | `total > balance` | Should be unreachable — abort 16 fires first. If you see it, `funded_total` accounting is wrong; stop and investigate. |
| `publish_root` aborts 6 | A root already exists | None for this escrow. Correction means a new escrow under a different `event_id`. |
| `initialise` aborts 12 | Window below 30 days | Almost certainly a units slip. Check seconds versus days. |
| A contributor cannot claim | Proof built against a different tree, or a different address | Rebuild their proof from the stored leaf set. Check the address matches the one in the leaf **byte for byte** — Aptos addresses have several valid spellings and the leaf commits to the 32 raw bytes. |
| `claim` aborts 7 | Invalid proof | The tree the root came from is not the tree the proof came from. Verify the root on chain matches the tree you are serving proofs against. |
| A claimant missed the deadline | The window elapsed | If not yet swept, they can still claim right now. If swept, only a successor escrow can pay them. |
| The sweep destination is wrong | Fixed at `initialise` | The sweep is unusable. Funds stay in escrow, which is the safe failure. Use a new escrow for future events. |
