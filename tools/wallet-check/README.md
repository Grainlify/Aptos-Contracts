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
npm install                 # once
node serve.js               # http://localhost:8899
```

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

## If a wallet fails step 2

That is not a dead end, it is the finding. It means that wallet needs the
self-paid fallback: the contributor pays their own gas, and the copy has to say
so rather than promising there is never a fee. Record it and move on.

## Caveat

**This page has not been run against a real wallet.** It was written without a
browser available, so treat a failure in the page's own plumbing as at least as
likely as a failure in the wallet — which is why every step prints what it
attempted alongside what came back.
