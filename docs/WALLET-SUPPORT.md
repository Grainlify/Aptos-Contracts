# Wallet support, and the copy that depends on it

Sponsorship is what lets somebody who has never held a token receive one without
first acquiring the token that pays for receiving it. It is the whole no-wallet
onboarding story. It also is not universal — it depends on the wallet doing one
specific thing, and wallets differ.

This file records which wallets do it, how we found out, and what the claim page
is allowed to say in each case.

## Exactly one capability varies

A sponsored claim is an AIP-39 fee-payer transaction. The contributor signs as
**sender**; we sign as **fee payer** and submit. The contract is not involved in
any of this — `claim` is an ordinary entry function and cannot tell who paid.

So there is one question per wallet, and it is not "does it support
sponsorship":

> Will it sign, **as sender**, a transaction whose fee payer is somebody else?

Three things follow that are easy to get wrong:

- **Signing is not the test. Signing the right message is.** A fee-payer
  transaction has its own signing message — different structure, different length
  (measured: 257 bytes against 223). Hand a wallet the inner `RawTransaction` and
  it will sign the *plain* message and return a perfectly well-formed
  authenticator. The chain rejects it with `INVALID_SIGNATURE`, which reads as a
  wallet bug and is not one.
- **A wallet that signs as fee payer has told you nothing.** Different code path.
- **Call shape is not capability.** Petra rejected two of four shapes with
  internal `TypeError`s. It supports this fully. The argument was the wrong type.

The check is `tools/wallet-check`. It verifies the returned signature against the
expected fee-payer message locally, before submitting, so a wallet that signs the
wrong payload is reported precisely instead of arriving later as a chain error.

## The table

Nothing goes in here that was not observed in a browser against the deployed
module on testnet. "Not yet run" means not yet run — it is not a prediction, and
copy may not treat it as one.

| Wallet | Detect | Step 1 `signMessage` | Step 2 sign as sender | Step 3 lands on chain | Verified |
|---|---|---|---|---|---|
| **Petra** (AIP-62) | ✅ | ✅ derives to connected address | ✅ `{rawTransaction, feePayerAddress: AccountAddress}` | ✅ [`0xe33e61b8…802b83`](https://explorer.aptoslabs.com/txn/0xe33e61b8b63a49f4fee77f21459a69b039cecd22efa423f3f60dc732d2802b83?network=testnet) | 18 Aug 2026 |
| **Aptos Connect** (Google) | — | — | — | — | not yet run |
| **Backpack** | — | — | — | — | not yet run |

Escrows are provisioned and funded for the two outstanding rows. Each is
initialised with 100,000 USDC minor units (0.1 USDC) and a 30-day window; neither
has a root, because **the leaf commits to the claiming address** and that address
is not known until the wallet connects.

| Event id | Escrow object | Root |
|---|---|---|
| `wallet-check-connect` | `0xabf6ab4133004c4231aced2acff42cade54554367171bea081b8742e88c3c6d7` | pending an address |
| `wallet-check-backpack` | `0x3bde1c88f2c524d7be14b6767411263e5aa10e2471b3fb933152ed2d96231135` | pending an address |

Connect the wallet, then publish:

```sh
cd tools/wallet-check
./setup-escrow.sh 0x<connected-address> wallet-check-connect
```

### The Petra result is stronger than "it works"

The claiming account's `sequence_number` was **0** — the claim was the first
transaction that account had ever sent. It held no APT, had no account on chain
until this transaction created one, and no USDC primary store until the claim
created that too. It received 100,000 USDC units and paid nothing.

That is the exact case the product depends on, tested in the exact state a real
first-time contributor is in. It is not a proxy for it.

## What the copy is allowed to say

Three states, and the rule that keeps the fallback a fallback: **we attempt
sponsorship by default and degrade only on evidence.** An unknown wallet gets the
optimistic path and falls back at runtime if signing fails. It does not get
pessimistic copy on the grounds that we have not tested it.

### State A — verified sponsor-capable

> **No fee.** We cover the network cost of sending this to you.

Say it next to the connected wallet, after connect, not as a page-level promise.
It is true of *that wallet*, which is what we verified.

### State B — verified not sponsor-capable

This is the one that needs care, because the obvious copy is wrong in a way that
strands people.

**Wrong:**

> Your wallet doesn't support gasless claims. A small network fee (~0.015 APT)
> applies.

Two failures. It names our internal category — "gasless claims" is not a thing the
reader has heard of — and, much worse, it quietly assumes they have APT. **A
first-time contributor has none.** For them this is not a small fee, it is a
closed door: they cannot claim without first acquiring the token, which is the
problem sponsorship exists to remove. Presenting the dead end as a minor cost is
the failure mode to avoid.

**Right:**

> Claiming from this wallet needs a small amount of APT — about 0.015 — to pay
> the network. If you don't have any, connect with **Petra** instead and we'll
> cover it. Your reward stays where it is either way.

Three things it has to do:

1. **Lead with the remedy, not the obstacle.** The remedy is another wallet, and
   it costs them nothing.
2. **Don't assume they hold APT.** "If you don't have any" is the branch that
   matters, and it is the majority case for the people this product is for.
3. **Say the reward is not at risk.** This is the moment somebody concludes they
   have lost something. Same rule as the exchange-address copy in the README.

Only name wallets in the table's verified column. Recommending an untested wallet
here would turn a fallback into a second dead end.

### State C — unknown wallet

Say nothing about fees before we know. Try sponsored; if step 2 fails at runtime,
move to state B's copy with the failure in hand.

**Wrong** (before connecting):

> Most wallets can claim with no fee.

Hedged, unverifiable by the reader, and it makes a promise we may have to
withdraw one screen later — which is worse than never having made it. Before
connect, the page talks about the amount and the address requirement. Fees are a
post-connect concern because they are a per-wallet fact.

### Never, in any state

- **"Free."** The claim costs the recipient nothing; it is not free. Somebody paid
  the gas, and on a page about money that distinction is worth keeping.
- **"Gas", "sponsored transaction", "fee payer", "gasless."** Ours, not theirs.
- **Any fee statement before connect.** It is not knowable yet.

## Keeping this honest

The table is the only authority for what copy may claim. If the claim page names a
wallet the table has not verified, the copy is ahead of the evidence — that is the
same defect as a docs claim the code does not support, and it should be treated
the same way.

Re-run the check when a wallet ships a major version. This is a wallet-behaviour
record with a shelf life, not a property of our contract.
