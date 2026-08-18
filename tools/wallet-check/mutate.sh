#!/usr/bin/env bash
# Mutation harness for the wallet boundary.
#
# A test that passes on a deliberately broken build is worse than no test, so
# every assertion here has to be shown to be load-bearing. Each mutation
# reintroduces a defect that ACTUALLY HAPPENED in this tool, or removes a check
# the page depends on. The suite must go red for every one.
#
# The control mutation is certified lethal by construction (it makes every
# response an accept). If the control survives, the harness is not running the
# tests and reports nothing rather than a clean sheet.
set -uo pipefail
cd "$(dirname "$0")"
F=index.html
BAK=$(mktemp); cp "$F" "$BAK"
restore() { cp "$BAK" "$F"; }
trap 'restore; rm -f "$BAK"' EXIT

run() { node boundary.test.mjs >/tmp/wc-mut.log 2>&1; }

killed=0; survived=0; declare -a SURV=()

mutate() {   # name, python-expression-pair
  local name="$1" from="$2" to="$3"
  restore
  python3 - "$from" "$to" <<'PY' || { echo "  SKIP    $name — pattern not found"; return; }
import sys
f=open("index.html").read()
if sys.argv[1] not in f: sys.exit(1)
open("index.html","w").write(f.replace(sys.argv[1], sys.argv[2], 1))
PY
  if run; then
    echo "  SURVIVED  $name"
    survived=$((survived+1)); SURV+=("$name")
  else
    echo "  killed    $name"
    killed=$((killed+1))
  fi
}

echo "=== control: make every response an accept ==="
restore
python3 - <<'PY'
f=open("index.html").read()
f=f.replace("function senderAuthenticator(response, what, expectedMsg, connectedAddress) {",
            "function senderAuthenticator(response, what, expectedMsg, connectedAddress) {\n  if (1) return { ok: true, auth: { serialize(){} }, scheme: 'ed25519', REBUILT_FROM_VERIFIED_BYTES: true };",1)
open("index.html","w").write(f)
PY
if run; then
  echo "  CONTROL SURVIVED — the harness is not exercising the boundary. Reporting nothing."
  exit 1
fi
echo "  control killed — the harness runs the tests"
echo ""
echo "=== real mutations ==="

mutate "drop the status check (the ORIGINAL Backpack bug)" \
  '  const status = r.status ?? r.result?.status;' \
  '  const status = undefined;'

mutate "restore the '?? r' fallback verbatim" \
  '  const v = r.args ?? r.account ?? (status !== undefined ? undefined : r);' \
  '  const v = r.args ?? r.account ?? r;'

mutate "treat a refusal as approved" \
  'if (typeof status === "string" && status.toLowerCase() !== "approved")' \
  'if (false)'

mutate "accept an unverified signature ('the chain will tell you')" \
  '  if (!verified)' \
  '  if (false && !verified)'

mutate "forward the wallet's own object instead of the rebuilt one" \
  '  return { ok: true, auth, scheme, bytes: hexOf(bytes),' \
  '  return { ok: true, auth: raw, scheme, bytes: hexOf(bytes),'

mutate "remove the Buffer branch from toBytes (Backpack's key shape)" \
  '  if (v.type === "Buffer" && Array.isArray(v.data)) return new Uint8Array(v.data);   // Backpack' \
  '  // removed'

mutate "skip the connected-account derivation check" \
  '  if (!scheme)' \
  '  if (!(scheme = scheme || "ed25519"), false)'

mutate "make two failures share a name" \
  'failure: "AUTHENTICATOR_HAS_NO_SIGNATURE"' \
  'failure: "AUTHENTICATOR_HAS_NO_PUBLIC_KEY"'

mutate "stop reading network names out of strings" \
  '      const m = x.toLowerCase().match(/(mainnet|testnet|devnet|local)/);' \
  '      const m = null;'

mutate "map every network name to the same id" \
  'const CHAIN_IDS = { mainnet: 1, testnet: 2 };' \
  'const CHAIN_IDS = { mainnet: 1, testnet: 1 };'

mutate "accept a 65-byte key as Ed25519" \
  '  if (pkBytes.length !== 32)' \
  '  if (false)'

echo ""
echo "=== $killed killed, $survived survived ==="
if [ "$survived" -gt 0 ]; then
  printf 'SURVIVED: %s\n' "${SURV[@]}"
  exit 1
fi
