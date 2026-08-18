# Wallet capability check

Three steps against a real escrow on testnet, run from a browser because a
wallet extension only talks to a web page.

**Every result is printed raw**, including errors — verbatim message, name, code,
keys and stack. Wallet errors are often generic, and the difference between
"user rejected", "method not supported" and "malformed transaction" decides
whether a failure is a wallet limitation or our bug.

## Running it

```sh
cd tools/wallet-check
npm install                                  # once
npm run build                                # once — bundles the SDK locally
node serve.js                                # http://localhost:8899
```

**Restarting?** `pkill -f "node serve.js"` first. A stale copy keeps the port and
answers with whatever routes it had when it started, which looks exactly like a
broken page — it cost a debugging round trip here. The server now refuses to
start rather than losing the race, but only if the old one is gone.

The SDK is **bundled from `node_modules`, not fetched from a CDN.** Two earlier
versions failed at import, both times because of dependency resolution rather
than anything to do with wallets:

1. `@aptos-labs/wallet-standard` declares `ts-sdk@^7.1.0` — a *range* — which
   resolved to a build where `AnyPublicKey` had moved. Pinning our own import did
   nothing, because the range belonged to the dependency.
2. The pinned CDN bundle still failed to evaluate in the browser.

A local bundle removes the class. The only things that can break now are this
page and the wallet, which is what it exists to test.

Then, in the browser:

1. **Detect wallets** → lists what is installed, by which standard, with the
   features each exposes.
2. **Connect** → shows the address.
3. In a second terminal, prepare an escrow whose leaf belongs to that address:

   ```sh
   ./setup-escrow.sh 0x<address-from-the-page>
   ```

   The leaf commits to the claiming address, so the escrow cannot be prepared
   until the wallet has connected. That is why this is a separate step and not
   something the page does — and it is also why **no key ever reaches the
   browser**. The script uses your `grainlify-testnet` CLI profile; the sponsor
   key stays inside `serve.js`.
4. **Derive escrow + leaf** in the page, and check the root it shows matches the
   one the script printed, with `alreadyClaimed: false`.
5. Run steps 1, 2 and 3.

**Use a fresh event id per wallet.** `publish_root` is write-once per escrow and
a claimed leaf cannot be reclaimed:

```sh
./setup-escrow.sh 0x<addr> wallet-check-petra
./setup-escrow.sh 0x<addr> wallet-check-connect
```

## What each step is actually testing

**1 — `signMessage`, and whether the returned key derives to the connected
address.** The derivation is the part that matters: a valid signature from *any*
key would otherwise verify *any* address. The page reports
`DERIVES_TO_CONNECTED_ADDRESS` separately from whether signing worked, because a
wallet can do the first and not let you check the second.

**2 — signing as SENDER of a fee-payer transaction, not submitted.** This is the
capability wallet support actually varies on, and it is a different code path
from signing *as* the fee payer. Split from step 3 deliberately: a wallet that
signs but whose transaction then fails on chain is a different finding from one
that will not sign at all.

The page tries several call shapes and reports which one worked. Wallets
disagree about this signature, and which shape a wallet accepts is itself the
result.

**3 — submit it sponsored.** The sender-signed transaction goes to `POST
/sponsor`, which signs as fee payer and submits. If this lands, the claimant
receives USDC having paid no gas — which is the property the whole no-wallet
onboarding story depends on.

## Wallet quirks found so far

**Petra** (AIP-62), tested 18 Aug 2026:

| Shape | Result |
| --- | --- |
| `aptos:signTransaction({transaction})` | `TypeError: Cannot read properties of undefined (reading 'bcsToHex')` — **inside Petra's own inpage.js**, not our code |
| `aptos:signTransaction({rawTransaction, feePayerAddress})` with a **hex string** | `TypeError: this.fee_payer_address.serialize is not a function` — inside Petra |
| `aptos:signTransaction({rawTransaction, feePayerAddress})` with an **`AccountAddress`** | **works** — this is the shape to use |
| `aptos:signTransaction({rawTransaction})` | signs, but over the **plain** message — verification catches it |

**The string error is not a missing capability.** Petra stored the value and later
called `.serialize()` on it, which means it reached the point of serialising the
fee payer — the support is there and the argument was the wrong *type*. It wants
an `AccountAddress` instance, not hex.

That was the fourth instance of one defect in this tool: a string handed to
something expecting a typed value. The first three were `vector<u8>` fields; this
one crosses into the extension. "Every `vector<u8>` from a helper" was too narrow
a rule — the general one is that a value crossing a typed boundary must be
constructed, never spelled.

So the call shape matters, which is why the page tries several and prints every
attempt. The first failing inside the wallet is a quirk to record, not something
to work around silently.

**But signing is not the test — signing the right message is.** A fee-payer
transaction has its own signing message, structurally different and a different
length from a plain one (measured: 223 bytes vs 257). Hand a wallet the inner
`RawTransaction` and it signs the *plain* message, returns a perfectly well-formed
authenticator, and the chain rejects the submission with `INVALID_SIGNATURE`.

That failure reads as a wallet bug and is not one. The page now sets the fee payer
before signing, and **verifies the returned signature locally against the expected
message before submitting** — so a wallet that signs the wrong payload is reported
here, precisely, instead of becoming a chain error.

### The shape that works

```js
await wallet.features["aptos:signTransaction"].signTransaction({
  rawTransaction:  txn.rawTransaction,          // the inner RawTransaction
  feePayerAddress: AccountAddress.from(SPONSOR) // the instance, never the hex string
})
```

Set `txn.feePayerAddress` before signing as well, so the message the wallet is
asked to sign is the fee-payer message and not the plain one. The page verifies
the returned signature against that exact message locally before it submits.

## If a wallet fails step 2

That is not a dead end, it is the finding. It means that wallet needs the
self-paid fallback: the contributor pays their own gas, and the copy has to say
so rather than promising there is never a fee. Record it and move on.

## Several wallet extensions installed?

Detect lists everything that registers and gives you a button per wallet — pick
one explicitly rather than letting the page take whichever registered first.

If results look strange, **try a clean Chrome profile with only Petra.**
Extensions genuinely fight over globals: a first run here produced
`Cannot redefine property: StacksProvider` from an unrelated Bitcoin wallet, and
`window.aptos` in particular can be claimed by something that is not the wallet
you think. The AIP-62 path is per-wallet and does not have that problem, which is
why the picker prefers it and legacy `window.aptos` is offered last.

## If the page itself breaks

A module-load failure used to be invisible: no output, no error in the page, dead
buttons, and the reason only in the console. An ES module cannot report its own
import failure from inside itself.

There is now a plain script that runs first, catches `error` and
`unhandledrejection`, and shows a **PAGE FAILURE** panel at the top. It also has a
four-second watchdog: the module sets a flag when it finishes, and if that never
happens the panel says so. If you see that panel, stop — nothing below it is
meaningful.

## Preparing an escrow before the wallet has connected

The leaf commits to the claiming address, so a root cannot be published until the
wallet is connected. `--prepare` does the half that does not need an address:

```sh
./setup-escrow.sh --prepare wallet-check-connect     # initialise + fund
./setup-escrow.sh 0x<addr> wallet-check-connect      # publish, once connected
```

Both modes are **safe to re-run.** Funding tops up to the target rather than
adding to it, because funding twice makes `funded_total` exceed the root and
`publish_root` then aborts with `E_ROOT_TOTAL_NOT_FUNDED` — a failure whose real
cause is two invocations, and which reads like a broken escrow. If a root already
exists the script prints it next to the leaf and stops rather than trying to
correct a write-once value.

## Where the plumbing was verified separately

The page's own dependencies were checked before any wallet was involved, and it
is worth keeping the distinction: the pinned bundle returns 200 at 1,029,031
bytes, its single sub-import resolves, it has **zero range dependencies** (the
thing that broke the first version), all six imported names are in its export
list, and the deployed module answers view calls.

None of that exercises a wallet — which is why every step prints what it
attempted alongside what came back. A failure in this page's plumbing is at least
as likely as one in the wallet.
