// Local server for the wallet capability check.
//
// Two jobs:
//   1. Serve index.html on http://localhost:8899
//   2. POST /sponsor — sign a sender-signed transaction as FEE PAYER and submit
//
// The sponsor's private key is read from the aptos CLI config and stays in this
// process. The browser never sees it and never needs it: the contributor signs
// as sender, this signs as fee payer, and the two authenticators are submitted
// together. That is the same split a production sponsor service would have.
const fs = require("fs");
const http = require("http");

// Where the API under test lives, and the session to call it with.
//
//   API_BASE=http://localhost:8080 API_TOKEN=<bearer> node serve.js
//
// The token is read from the environment and never written to a file or echoed
// to the page: it is a live session, and the point of this harness is to prove
// the endpoints, not to leave a credential lying in a scratch directory.
const API_BASE = process.env.API_BASE || "http://localhost:8080";
const API_TOKEN = process.env.API_TOKEN || "";
const path = require("path");
const {
  Aptos, AptosConfig, Network, Account, Ed25519PrivateKey,
  SimpleTransaction, AccountAuthenticator, Deserializer,
} = require("@aptos-labs/ts-sdk");

const PORT = 8899;
const CONFIG = process.env.APTOS_CONFIG || path.join(__dirname, "..", "..", ".aptos", "config.yaml");
const PROFILE = process.env.APTOS_PROFILE || "grainlify-testnet";

function sponsorAccount() {
  const txt = fs.readFileSync(CONFIG, "utf8");
  // Find the named profile's key rather than the first key in the file.
  const block = txt.split(/^\s{2}(?=\S)/m).find((b) => b.startsWith(PROFILE + ":"));
  const src = block || txt;
  const m = src.match(/private_key:\s*"?(?:ed25519-priv-)?(0x[0-9a-fA-F]+)"?/);
  if (!m) throw new Error(`no private_key for profile ${PROFILE} in ${CONFIG}`);
  return Account.fromPrivateKey({ privateKey: new Ed25519PrivateKey(m[1]) });
}

const aptos = new Aptos(new AptosConfig({ network: Network.TESTNET }));
const sponsor = sponsorAccount();
const hexToBytes = (h) => Uint8Array.from(Buffer.from(h.replace(/^0x/, ""), "hex"));

const server = http.createServer(async (req, res) => {
  const send = (code, body, type = "application/json") => {
    res.writeHead(code, { "Content-Type": type, "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Content-Type" });
    res.end(typeof body === "string" ? body : JSON.stringify(body, null, 2));
  };

  if (req.method === "OPTIONS") return send(204, "");

  if (req.method === "GET" && (req.url === "/" || req.url.startsWith("/index"))) {
    return send(200, fs.readFileSync(path.join(__dirname, "index.html"), "utf8"), "text/html");
  }

  if (req.method === "GET" && req.url.startsWith("/vendor/")) {
    const f = path.join(__dirname, req.url.split("?")[0]);
    if (!f.startsWith(path.join(__dirname, "vendor"))) return send(403, { error: "no" });
    if (!fs.existsSync(f)) {
      return send(404, { error: "vendor bundle missing - run: npx esbuild vendor/entry.js --bundle --format=esm --platform=browser --outfile=vendor/ts-sdk.mjs" });
    }
    return send(200, fs.readFileSync(f, "utf8"), "application/javascript");
  }

  // --- proxy to the Grainlify API -----------------------------------------
  //
  // The browser cannot call the API directly (different origin, and the page
  // holds no session), so the harness forwards. It attaches the bearer token
  // supplied on the command line, which is the ONLY thing it adds - the body
  // and the path are passed through untouched, so what this exercises is the
  // real endpoint and not a convenience wrapper around it.
  if (req.url.startsWith("/api/")) {
    const target = API_BASE + req.url.slice(4);
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", async () => {
      try {
        const r = await fetch(target, {
          method: req.method,
          headers: {
            "Content-Type": "application/json",
            ...(API_TOKEN ? { Authorization: "Bearer " + API_TOKEN } : {}),
          },
          body: req.method === "GET" ? undefined : body,
        });
        const text = await r.text();
        res.writeHead(r.status, { "Content-Type": "application/json" });
        res.end(text);
      } catch (e) {
        res.writeHead(502, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ proxy_error: String(e && e.message || e), target }));
      }
    });
    return;
  }

  if (req.method === "GET" && req.url === "/api-info") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ api: API_BASE, tokenPresent: Boolean(API_TOKEN) }));
    return;
  }

  if (req.method === "GET" && req.url === "/sponsor-info") {
    return send(200, { sponsor: sponsor.accountAddress.toString(), profile: PROFILE, network: "testnet" });
  }

  if (req.method === "POST" && req.url === "/sponsor") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", async () => {
      try {
        const { transaction, senderAuth } = JSON.parse(body);

        const txn = SimpleTransaction.deserialize(new Deserializer(hexToBytes(transaction)));
        const senderAuthenticator = AccountAuthenticator.deserialize(new Deserializer(hexToBytes(senderAuth)));

        // The sender signed over a specific fee payer. If that is not this
        // account, the two signatures cover different messages and the chain
        // rejects it as INVALID_SIGNATURE - which reads as a wallet fault and is
        // not one. Refuse here, where the cause is still visible.
        const signedOver = txn.feePayerAddress ? txn.feePayerAddress.toString() : null;
        const ours = sponsor.accountAddress.toString();
        if (signedOver && signedOver !== "0x0" && signedOver.toLowerCase() !== ours.toLowerCase()) {
          return send(200, { ok: false, stage: "sponsor",
            error: `the sender signed a transaction whose fee payer is ${signedOver}, ` +
                   `but this sponsor is ${ours}. Those are different signing messages.` });
        }
        const feePayerAuthenticator = aptos.transaction.signAsFeePayer({ signer: sponsor, transaction: txn });

        const submitted = await aptos.transaction.submit.simple({
          transaction: txn, senderAuthenticator, feePayerAuthenticator,
        });
        const result = await aptos.waitForTransaction({ transactionHash: submitted.hash });

        // Everything raw. No summarising - the point of this tool is the
        // verbatim result.
        send(200, {
          ok: result.success, hash: submitted.hash,
          gas_used: result.gas_used, gas_unit_price: result.gas_unit_price,
          vm_status: result.vm_status, raw: result,
        });
      } catch (e) {
        send(200, { ok: false, stage: "sponsor", error: String(e && e.message || e),
          name: e && e.name, stack: e && e.stack });
      }
    });
    return;
  }

  send(404, { error: "not found", url: req.url });
});

server.on("error", (e) => {
  if (e.code === "EADDRINUSE") {
    console.error(`\nPORT ${PORT} IS ALREADY IN USE.\n\n` +
      `An older copy of this server is still running and will answer requests\n` +
      `with whatever routes it had when it started - which looks exactly like a\n` +
      `broken page. Kill it first:\n\n  pkill -f "node serve.js"\n`);
    process.exit(1);
  }
  throw e;
});

server.listen(PORT, () => {
  console.log(`wallet-check on http://localhost:${PORT}`);
  console.log(`sponsor: ${sponsor.accountAddress.toString()}  (profile ${PROFILE})`);
  console.log(`config:  ${CONFIG}`);
});
