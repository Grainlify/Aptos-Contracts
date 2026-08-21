# Wallet support, and the claim flow that follows from it

> ## ⚠ CORRECTION — SPONSORSHIP IS DEMONSTRATED, NOT DEPLOYED
>
> **Nothing in production pays a contributor's gas.** The sponsored claim
> recorded below really happened, and the fee payer was a **local script**:
> `tools/wallet-check/serve.js`, reading a testnet key from a gitignored
> `.aptos/config.yaml` and listening on `localhost:8899`. A contributor clicking
> Claim goes nowhere near it.
>
> There is no fee-payer code in `Grainlify-Backend` or `Grainlify-Frontend` —
> the backend only makes read-only view calls and never builds, signs or submits
> a transaction. `internal/chainops` states it plainly: *the contributor submits
> this, signing with their own key and paying their own gas.*
>
> **So the flow copy below is a specification, not a description**, and two of
> its sentences are currently false in production:
> *"We cover the network cost"* and *"nobody on the supported path pays
> anything."* They are left in place, marked, because they describe the intended
> flow that the claim screen should implement — not because they are true today.
>
> Tracked as **[Grainlify-Backend#537](https://github.com/Grainlify/Grainlify-Backend/issues/537)**. On testnet this hides: APT is free from a
> faucet, so a self-paid rehearsal passes while exercising a path no real
> deployment uses, and the faucet is exactly what will not be there.
>
> ### Delete this block when — and only when — all of these hold
>
> 1. A production endpoint signs as fee payer and submits (the deployed
>    equivalent of `serve.js`'s `/sponsor`).
> 2. A contributor claim has landed **through that endpoint**, with the
>    transaction hash recorded here beside the milestone below.
> 3. `grep -rniE "feePayer|fee_payer" Grainlify-Backend --include="*.go"` returns
>    the sponsor service rather than nothing.
>
> If you are deleting this because the copy "looks fixed", stop: the copy was
> never the problem.

**Decision: the first payout is Petra only.** Petra is the one wallet verified end
to end against the deployed module. Backpack could not be tested. Aptos Connect
has not been tried. Rather than build capability detection and adaptive copy for
wallets we cannot speak to, the flow instructs Petra and does not attempt others.

## The table

Three verdicts. Nothing here is a prediction, and the two negatives are not the
same kind of negative.

| Wallet | Verdict | Basis |
|---|---|---|
| **Petra** | **Verified end to end** | Sponsored claim landed on testnet: [`0xe33e61b8…802b83`](https://explorer.aptoslabs.com/txn/0xe33e61b8b63a49f4fee77f21459a69b039cecd22efa423f3f60dc732d2802b83?network=testnet). Sender `sequence_number: 0`, `fee_payer_signature`, full amount received, nothing paid. 18 Aug 2026. |
| **Backpack** | **Untestable** | Connected on **mainnet** against a testnet escrow, so its refusal of `signTransaction` says nothing about capability. `signMessage` worked. 18 Aug 2026. |
| **Aptos Connect** (Google) | **Untested** | Not attempted. |

**Petra's working call shape**, which is the part a production client needs:

```js
await wallet.features["aptos:signTransaction"].signTransaction({
  rawTransaction:  txn.rawTransaction,           // the inner RawTransaction
  feePayerAddress: AccountAddress.from(SPONSOR), // the instance, never the hex string
})
```

Set `txn.feePayerAddress` before signing, so the wallet is asked to sign the
**fee-payer** message rather than the plain one — different structure, different
length (257 bytes against 223). Hand Petra the bare `RawTransaction` and it signs
the plain message, returns a well-formed authenticator, and the chain rejects it
as `INVALID_SIGNATURE`.

Two of the four shapes tried failed inside Petra's own code, neither for lack of
support: `{transaction}` threw on `bcsToHex`, and `feePayerAddress` as a hex
string threw `this.fee_payer_address.serialize is not a function` — Petra had
reached the point of serialising the fee payer, so the support was there and the
argument was the wrong type.

### Why Backpack is "untestable" and not "unsupported"

It was on mainnet. Every failure below that point looks exactly like a wallet
limitation, which is why the check now refuses to proceed on a network mismatch.
Recording it as incapable would be a false negative propagating into copy — the
same defect as recording an untested wallet as capable, in the other direction.

Its escrow is ready for a re-run whenever we want one: `wallet-check-backpack`,
published, funded 100,000, `is_claimed: false`. One quirk is worth keeping
regardless of the verdict: Backpack returns a public key as
`{"type":"Buffer","data":[...]}`, a Node `Buffer` through `JSON.stringify`, with
none of the methods an SDK key object has.

## What the contributor actually sees, start to finish

The first payout runs on **Aptos testnet**, which is a locked decision for this
workstream. That has one visible consequence — step 3 — and it is the largest
piece of friction in the flow. Lines that change on mainnet are marked.

### 1. The notification

> **You have a reward waiting — 12.50 USDC**
>
> For your merged contributions to `org/repo` between June and August.
> Claim it by 12 March 2028.

The date is in front of the person from the first contact, not only in the terms.
The deadline wording rules are in the [README](../README.md#copy-for-the-terms-and-the-claim-page--the-obvious-wording-is-false) —
in short, the date is when we *may* return unclaimed funds, not when the claim
stops working, and missing it is recoverable by asking.

### 2. The claim page, before anything is connected

> **12.50 USDC is yours to claim**
>
> To receive it you'll need an Aptos wallet — an app that holds the reward for
> you and that only you can open.
>
> We've tested this end to end with **Petra**, so that's the one we can walk you
> through. Setting it up takes about three minutes.
>
> `[ Set up Petra ]`  ·  `[ I already have Petra ]`

Nothing about fees appears here, or anywhere. On the Petra path nobody pays
anything, so there is no fee to disclose and no fallback to explain.

Note the framing: **"we've tested this end to end with Petra"**, not "Petra is
required". That is what is true, and it ages correctly — when Aptos Connect is
verified we add a button, and no sentence on this page becomes a lie.

### 3. Setting up Petra — and the network step

> **1. Install Petra** — [petra.app](https://petra.app), Chrome or Brave.
> **2. Create a wallet.** Write the recovery phrase down on paper. Nobody at
> Grainlify can see it, and nobody can recover it for you.
> **3. Switch Petra to Testnet.** Settings → Network → Testnet.
>
> That third step matters: this payout runs on Aptos **testnet**, and Petra
> starts on mainnet. If you skip it, the claim button won't work and it won't be
> obvious why.

**On mainnet, step 3 disappears entirely** and this screen becomes two steps. It
is here because it is true now, and because a contributor who skips it hits a
failure whose cause is invisible from the wallet's side.

### 4. Connect, and prove the address is yours

> **Connect Petra**
>
> We'll ask Petra to sign a short message. That proves you control this address —
> it doesn't move anything and it doesn't cost anything.
>
> `[ Connect Petra ]`

After connect, and before the claim button is enabled, two runtime checks. Both
fail closed.

**If it isn't Petra:**

> **This looks like a different wallet — {name}.**
>
> Petra is the only wallet we've verified this payout with end to end, so it's
> the only one we'll ask you to claim with. Anything else might work, and we're
> not going to find that out with your reward.
>
> Your reward stays exactly where it is. `[ Set up Petra ]`

**If Petra is on the wrong network:**

> **Petra is on Mainnet, and this payout is on Testnet.**
>
> Switch it in Settings → Network → Testnet, then connect again. Nothing is lost
> by switching back and forth.

Both are blocks, not warnings. The alternative is discovering the failure at
claim time with money involved, and a wallet error at that moment reads as our
software losing somebody's reward.

The wallet check must run **after** connect, not from the installed-wallet list:
another extension can claim `window.aptos`, and one did during testing — a
Bitcoin wallet threw `Cannot redefine property: StacksProvider` and took the
global. Trusting the list rather than the responder is how you end up asking the
wrong extension to sign.

### 5. The claim

> **Claim 12.50 USDC**
>
> Petra will ask you to approve this. We cover the network cost, so the full
> 12.50 arrives.
>
> `[ Claim ]`

"We cover the network cost" is the only fee sentence anywhere in the flow, and it
is a statement about what we do rather than a promise about what wallets support.

**Not true in production yet** — see the correction at the top of this file.
Until the sponsor service exists, a contributor pays their own gas, and a
contributor who has never held APT cannot pay it at all.

### 6. Done

> **12.50 USDC is in your wallet.**
>
> [View the transaction] · It may take a moment to appear in Petra.

The last line exists because a first-time recipient's token store is *created* by
this transaction. Petra can take a moment to show an asset it has never held, and
that gap is the most likely reason somebody reports the payout as missing when it
has already arrived.

## What we deliberately did not build

**No capability detection across wallets.** One verified wallet needs no
detection — it needs a check that it is that wallet. Detection exists to choose
between options, and there is one option.

**No fee-fallback copy.** Petra supports sponsorship, so nobody on the supported
path pays anything, and copy for a case that cannot currently arise is copy that
will be wrong by the time it can.

**This reasoning is currently inverted.** The case it dismisses — a contributor
paying their own gas — is the ONLY case that can arise today, because no sponsor
service is deployed. The decision stands for the flow this document specifies;
it is wrong as a description of what ships now. It comes back with the second wallet, if that
wallet needs it.

**No adaptive copy.** Same reason. Three copy states for one verified wallet is
machinery serving a table with one row in it.

## The self-paid fallback is not code, and cannot be deleted

Worth stating precisely, because "keep the fallback code" implies there is some to
keep and there is not.

`claim` is a plain `public entry fun`. The contract has no idea who pays for gas
and no way to find out — sponsorship is entirely an AIP-39 transaction-layer
concern, and the only `sponsor` in the module is the account that *funds* an
escrow, which is a different thing. So a contributor paying their own gas is not
a feature we maintain; it is the **absence of a restriction**, and the only way to
lose it is to deliberately add one.

It is also, incidentally, the better-tested path. A Move unit test cannot
construct a fee-payer transaction, so **every one of the 16 tests that calls
`claim` is a self-paid claim** — verified: the suite contains no fee-payer
construct at all. Sponsorship is the path that needed a testnet observation,
precisely because it is the one the test suite structurally cannot reach.

## Keeping this honest

The table is the only authority for what the flow may name. If the claim page
names a wallet the table has not verified, the copy is ahead of the evidence —
the same defect as a docs claim the code does not support, and to be treated the
same way.

Two rules the Backpack run earned:

- **A failure only becomes a verdict once the setup is known good.** A wallet on
  the wrong network produces findings shaped exactly like wallet limitations.
  "Untestable" is a legitimate verdict; a guess is not.
- **Re-run on a wallet's major version.** This is a record of wallet behaviour
  with a shelf life, not a property of our contract.
