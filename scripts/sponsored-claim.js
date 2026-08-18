// Verify a sponsored claim end to end against a running node.
//
// This is the script that produced the first real claim: the claimant received
// the full amount and paid no gas, and the sponsor's balance moved by exactly
// gas_used x gas_unit_price and nothing else.
//
// TO RUN IT YOURSELF, change three things and nothing else:
//
//   CONFIG   the path to your .aptos/config.yaml
//   ADMIN    the address the module is published under
//   ESCROW   the escrow object address, from escrow_address(admin, event_id)
//
// The logic below is unchanged from the run recorded in report 10. To test a
// wallet rather than a local key, replace the `claimant` account with a wallet
// signer and leave everything else alone - the point of the check is that the
// contributor signs as SENDER of a fee-payer transaction, which is the path
// wallet support varies on.
//
// It needs @aptos-labs/ts-sdk. It reads private keys from an aptos CLI config,
// so point it at a throwaway profile, never one holding real value.

// Prove that a claim can be paid for by a third party, and that the third party
// gains nothing but a gas bill.
//
// Local network, throwaway escrow, synthetic leaf. No real root, no real
// allocation, no salt from any settlement.
const fs = require("fs");
const yaml = null;
const {
  Aptos, AptosConfig, Network, Account, Ed25519PrivateKey, MoveVector,
} = require("@aptos-labs/ts-sdk");

const CONFIG = "./.aptos/config.yaml";

// Minimal parse: profile name -> private_key. Local throwaway keys only.
function keys() {
  const txt = fs.readFileSync(CONFIG, "utf8");
  const out = {};
  let cur = null;
  for (const line of txt.split("\n")) {
    const p = line.match(/^\s{2}(\w+):\s*$/);
    if (p) { cur = p[1]; continue; }
    const k = line.match(/^\s+private_key:\s*"?(?:ed25519-priv-)?(0x[0-9a-fA-F]+)"?/);
    if (k && cur) out[cur] = k[1];
  }
  return out;
}

function acct(hex) {
  return Account.fromPrivateKey({ privateKey: new Ed25519PrivateKey(hex) });
}

(async () => {
  const aptos = new Aptos(new AptosConfig({ network: Network.LOCAL }));
  const k = keys();
  const claimant = acct(k.claimant);
  const sponsor = acct(k.sponsor);
  const ADMIN = "0x819b7319aeff7c3dd415dab8e2677ee3dc54562125f1514118c46b48a773ef81";
  const ESCROW = "0x319492c5ac477628986088894b2d886c81d84300048031418d243214e866b574";
  // vector<u8> must be bytes, not a hex string - a string is BCS-encoded as a
  // string and arrives at the module as the wrong length. The contract caught it
  // with E_BAD_DIGEST_LENGTH, which is the assertion doing its job.
  const IDENT = new Uint8Array(32).fill(0x22);
  const AMOUNT = 1000000;

  const apt = async (a) => Number(await aptos.getAccountAPTAmount({ accountAddress: a }));

  const before = {
    claimant: await apt(claimant.accountAddress),
    sponsor: await apt(sponsor.accountAddress),
  };
  console.log("BEFORE  claimant:", before.claimant, " sponsor:", before.sponsor);

  // The contributor is the SENDER. The sponsor is the fee payer. This is the
  // shape a wallet has to be able to sign, and the one support varies on.
  const txn = await aptos.transaction.build.simple({
    sender: claimant.accountAddress,
    withFeePayer: true,
    options: { maxGasAmount: 20000 },
    data: {
      function: `${ADMIN}::escrow::claim`,
      functionArguments: [ESCROW, IDENT, AMOUNT, new MoveVector([])],
    },
  });

  const senderAuth = aptos.transaction.sign({ signer: claimant, transaction: txn });
  const feePayerAuth = aptos.transaction.signAsFeePayer({ signer: sponsor, transaction: txn });

  const submitted = await aptos.transaction.submit.simple({
    transaction: txn,
    senderAuthenticator: senderAuth,
    feePayerAuthenticator: feePayerAuth,
  });
  const res = await aptos.waitForTransaction({ transactionHash: submitted.hash });
  console.log("TX", submitted.hash, "success:", res.success, "gas:", res.gas_used, "x", res.gas_unit_price);

  const after = {
    claimant: await apt(claimant.accountAddress),
    sponsor: await apt(sponsor.accountAddress),
  };
  console.log("AFTER   claimant:", after.claimant, " sponsor:", after.sponsor);

  const fee = Number(res.gas_used) * Number(res.gas_unit_price);
  console.log("");
  console.log("claimant delta:", after.claimant - before.claimant, "(want exactly +" + AMOUNT + ", i.e. paid no gas)");
  console.log("sponsor  delta:", after.sponsor - before.sponsor, "(want exactly -" + fee + ", i.e. the fee and nothing else)");
  console.log("");
  console.log("claimant received the full amount and paid nothing:",
    after.claimant - before.claimant === AMOUNT);
  console.log("sponsor paid the fee and gained nothing:",
    after.sponsor - before.sponsor === -fee);
})().catch(e => { console.error("FAILED:", e.message); process.exit(1); });
