// Tests for the wallet boundary, run against the code sliced out of index.html.
//
// The case that matters most is the first one: it is the VERBATIM response
// Backpack returned, which the previous version reported as SIGNED: true.
import { execSync } from "node:child_process";
execSync("node extract-boundary.mjs", { cwd: import.meta.dirname });

const B = await import("./boundary.generated.mjs");
const { Account, Ed25519PrivateKey } = await import("@aptos-labs/ts-sdk");

let pass = 0, fail = 0;
const t = (name, fn) => {
  try { fn(); console.log(`  ok    ${name}`); pass++; }
  catch (e) { console.log(`  FAIL  ${name}\n        ${e.message}`); fail++; }
};
const eq = (got, want, what) => {
  if (got !== want) throw new Error(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
};

// A real Ed25519 account, and a real signature over a known message.
const acct = Account.generate();
const MSG = new Uint8Array(257).fill(7);          // stands in for the fee-payer message
const WRONG = new Uint8Array(223).fill(7);        // ... and for the plain one
const sigBytes = acct.sign(MSG).toUint8Array();
const pkBytes = acct.publicKey.toUint8Array();
const ADDR = acct.accountAddress.toString();
const authOf = (pk, sig) => ({ public_key: pk, signature: sig });

console.log("\n--- the Backpack response, verbatim ---");

// This is exactly what the wallet returned. It has no args and no
// authenticator, so `r.args ?? r.authenticator ?? r` yielded the object itself.
const BACKPACK_REJECTION = { status: "Rejected" };

t("a Rejected response is WALLET_REJECTED, not a signature", () => {
  const g = B.senderAuthenticator(BACKPACK_REJECTION, "shape", MSG, ADDR);
  eq(g.ok, false, "ok");
  eq(g.failure, "WALLET_REJECTED", "failure");
});

t("a Rejected response never yields an authenticator", () => {
  const g = B.senderAuthenticator(BACKPACK_REJECTION, "shape", MSG, ADDR);
  if (g.auth !== undefined) throw new Error("a refusal produced an auth object");
});

t("the refusal detail says it cannot tell user-declined from wallet-declined", () => {
  const g = B.senderAuthenticator(BACKPACK_REJECTION, "shape", MSG, ADDR);
  if (!/does not distinguish/.test(g.detail)) throw new Error(`detail was: ${g.detail}`);
});

console.log("\n--- the happy path ---");

t("a correct signature verifies and rebuilds", () => {
  const g = B.senderAuthenticator({ status: "Approved", args: authOf(pkBytes, sigBytes) }, "shape", MSG, ADDR);
  if (!g.ok) throw new Error(`rejected a good signature: ${g.failure} ${g.detail}`);
  eq(g.scheme, "ed25519", "scheme");
  eq(g.REBUILT_FROM_VERIFIED_BYTES, true, "rebuilt flag");
});

t("the rebuilt authenticator serialises — the step-3 TypeError cannot recur", () => {
  const g = B.senderAuthenticator({ status: "Approved", args: authOf(pkBytes, sigBytes) }, "shape", MSG, ADDR);
  if (typeof g.auth.serialize !== "function") throw new Error("auth has no serialize()");
  if (!B.serialised(g.auth)) throw new Error("auth did not serialise");
});

t("a legacy response with no status field still works", () => {
  const g = B.senderAuthenticator(authOf(pkBytes, sigBytes), "legacy", MSG, ADDR);
  if (!g.ok) throw new Error(`${g.failure}: ${g.detail}`);
});

console.log("\n--- Backpack's Buffer-shaped public key ---");

const BUFFER_PK = { type: "Buffer", data: [...pkBytes] };

t("a JSON-serialised Node Buffer public key is read", () => {
  eq(B.bytesOfLength(BUFFER_PK, [32], 0)?.length, 32, "length");
});

// toBytes is the documented single normaliser, so its Buffer branch is pinned
// directly. Removing it survived a first mutation run: bytesOfLength descends
// into a generic "data" key and reached the same bytes by another route. The
// branch stays because it documents the quirk - so it gets its own test rather
// than relying on the descent to cover it.
t("toBytes reads a Buffer shape directly, not only via the descent", () => {
  const got = B.toBytes(BUFFER_PK);
  if (!got) throw new Error("toBytes returned null for {type:'Buffer',data:[...]}");
  eq(got.length, 32, "length");
  eq([...got].join(","), [...pkBytes].join(","), "bytes");
});

t("a Buffer-shaped key verifies end to end", () => {
  const g = B.senderAuthenticator({ status: "Approved", args: authOf(BUFFER_PK, { type: "Buffer", data: [...sigBytes] }) }, "shape", MSG, ADDR);
  if (!g.ok) throw new Error(`${g.failure}: ${g.detail}`);
});

console.log("\n--- signing the wrong message ---");

t("a signature over the plain message is SIGNATURE_OVER_WRONG_MESSAGE", () => {
  const wrongSig = acct.sign(WRONG).toUint8Array();
  const g = B.senderAuthenticator({ status: "Approved", args: authOf(pkBytes, wrongSig) }, "shape", MSG, ADDR);
  eq(g.ok, false, "ok");
  eq(g.failure, "SIGNATURE_OVER_WRONG_MESSAGE", "failure");
});

t("NO shape can reach step 3 unverified — there is no null/unknown verdict", () => {
  // Every rejection path must be a named failure, never an accept.
  for (const [label, resp] of [
    ["rejection", BACKPACK_REJECTION],
    ["empty", null],
    ["approved but empty", { status: "Approved" }],
    ["no key or sig", { status: "Approved", args: {} }],
    ["sig only", { status: "Approved", args: { signature: sigBytes } }],
    ["key only", { status: "Approved", args: { public_key: pkBytes } }],
    ["garbage key", { status: "Approved", args: authOf({ nope: 1 }, sigBytes) }],
    ["garbage sig", { status: "Approved", args: authOf(pkBytes, { nope: 1 }) }],
  ]) {
    const g = B.senderAuthenticator(resp, label, MSG, ADDR);
    if (g.ok) throw new Error(`${label} was ACCEPTED`);
    if (!g.failure) throw new Error(`${label} produced no failure name`);
  }
});

t("each failure cause has its own name", () => {
  const names = [
    B.senderAuthenticator(null, "x", MSG, ADDR).failure,
    B.senderAuthenticator({ status: "Rejected" }, "x", MSG, ADDR).failure,
    B.senderAuthenticator({ status: "Approved" }, "x", MSG, ADDR).failure,
    B.senderAuthenticator({ status: "Approved", args: {} }, "x", MSG, ADDR).failure,
    B.senderAuthenticator({ status: "Approved", args: { signature: sigBytes } }, "x", MSG, ADDR).failure,
    B.senderAuthenticator({ status: "Approved", args: { public_key: pkBytes } }, "x", MSG, ADDR).failure,
    B.senderAuthenticator({ status: "Approved", args: authOf({ nope: 1 }, sigBytes) }, "x", MSG, ADDR).failure,
    B.senderAuthenticator({ status: "Approved", args: authOf(pkBytes, { nope: 1 }) }, "x", MSG, ADDR).failure,
  ];
  if (new Set(names).size !== names.length)
    throw new Error(`names collide, so a reader cannot tell the causes apart: ${names.join(", ")}`);
});

console.log("\n--- a signature from the wrong key ---");

t("a key that is not the connected account is refused", () => {
  const other = Account.generate();
  const g = B.senderAuthenticator(
    { status: "Approved", args: authOf(other.publicKey.toUint8Array(), other.sign(MSG).toUint8Array()) },
    "shape", MSG, ADDR);
  eq(g.ok, false, "ok");
  eq(g.failure, "SIGNING_KEY_IS_NOT_THE_CONNECTED_ACCOUNT", "failure");
});

console.log("\n--- key schemes this page cannot rebuild ---");

// Untested in the first version, and a mutation removing the length guard
// survived because of it. Without the guard a 65-byte key reaches
// new Ed25519PublicKey(), which throws out of the boundary entirely - turning a
// nameable finding into a page error.
t("a 65-byte (secp256k1-shaped) key is UNSUPPORTED_KEY_SCHEME, not silently Ed25519", () => {
  const k65 = new Uint8Array(65).fill(3);
  let g;
  try { g = B.senderAuthenticator({ status: "Approved", args: authOf(k65, sigBytes) }, "shape", MSG, ADDR); }
  catch (e) { throw new Error(`threw instead of returning a named failure: ${e.message}`); }
  eq(g.ok, false, "ok");
  eq(g.failure, "UNSUPPORTED_KEY_SCHEME", "failure");
});

console.log("\n--- chain normalisation ---");

t('Backpack\'s "aptos:mainnet" normalises to chain id 1', () => {
  const n = B.normaliseChain({ chainId: "aptos:mainnet" });
  eq(n.id, 1, "id"); eq(n.name, "mainnet", "name");
});

t("Petra's numeric chainId 2 normalises to testnet", () => {
  const n = B.normaliseChain({ chainId: 2 });
  eq(n.id, 2, "id"); eq(n.name, "testnet", "name");
});

t("mainnet and testnet do not compare equal", () => {
  if (B.normaliseChain({ chainId: "aptos:mainnet" }).id === B.normaliseChain({ chainId: 2 }).id)
    throw new Error("a mainnet wallet would be allowed to sign against testnet");
});

t('a bare name string is understood', () => {
  eq(B.normaliseChain({ name: "Testnet" }).id, 2, "id");
});

t("an unreadable network reports null rather than guessing", () => {
  const n = B.normaliseChain({ something: "else" });
  eq(n.id, null, "id"); eq(n.name, null, "name");
});

console.log(`\n${fail === 0 ? "PASS" : "FAIL"} — ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
