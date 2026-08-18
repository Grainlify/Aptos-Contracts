#!/usr/bin/env bash
#
# Publish a small test escrow whose single leaf belongs to a connected wallet.
#
# Run this AFTER clicking Connect on the page, with the address it shows. The
# leaf commits to the claiming address, so the escrow cannot be prepared until
# that address is known - which is why this is a separate step rather than
# something the page does.
#
# It uses your existing aptos CLI profile. No key ever reaches the browser.
#
#   ./setup-escrow.sh 0x<wallet-address> [event-id] [amount-minor]
set -euo pipefail

# Two modes, because the leaf commits to the claiming address and that address
# is unknown until a wallet has connected:
#
#   ./setup-escrow.sh --prepare <event-id> [amount]     initialise + fund only
#   ./setup-escrow.sh 0x<addr>  <event-id> [amount]     everything
#
# Safe to re-run either way. Funding is topped up to the target rather than added
# to, because funding twice would make funded_total exceed the root and
# publish_root would then abort with E_ROOT_TOTAL_NOT_FUNDED - a confusing
# failure whose cause is two invocations, not anything wrong with the escrow.
if [ "${1:-}" = "--prepare" ]; then
  PREPARE_ONLY=1; CLAIMANT=""; EVENT_ID="${2:?usage: ./setup-escrow.sh --prepare <event-id> [amount]}"; AMOUNT="${3:-100000}"
else
  PREPARE_ONLY=0
  CLAIMANT="${1:?usage: ./setup-escrow.sh 0x<wallet-address> <event-id> [amount]  (or --prepare <event-id>)}"
  EVENT_ID="${2:-wallet-check}"; AMOUNT="${3:-100000}"
fi
PROFILE="${APTOS_PROFILE:-grainlify-testnet}"
MODULE="${APTOS_MODULE:-0x1b419fe2b8c2a694eda8398af4bb6f6980915f9e3ed856b3b0fb4f26597f22c9}"
USDC="${APTOS_USDC:-0x69091fbab5f7d635ee7ac5098cf0c1efbe31d68fec0f2cd565e8d168daf52832}"
IDENT="${APTOS_IDENT:-0x2222222222222222222222222222222222222222222222222222222222222222}"

EVENT_HEX=$(printf '%s' "$EVENT_ID" | xxd -p | tr -d '\n')
say() { printf '\n=== %s ===\n' "$1"; }
run() { aptos move run --profile "$PROFILE" --assume-yes "$@" 2>&1 \
        | grep -E '"success"|"vm_status"|"transaction_hash"|Error|abort' || true; }
view() { aptos move view --profile "$PROFILE" "$@" 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["Result"][0])'; }

say "claimant $CLAIMANT / event '$EVENT_ID' / $AMOUNT USDC minor units"

ESCROW=$(view --function-id ${MODULE}::escrow::escrow_address --args address:$MODULE hex:$EVENT_HEX)
echo "escrow: $ESCROW"

say "initialise (skipped if it already exists)"
run --function-id ${MODULE}::escrow::initialise \
    --args hex:$EVENT_HEX address:$USDC address:$MODULE u64:2592000

FUNDED=$(view --function-id ${MODULE}::escrow::funded_total --args address:$ESCROW || echo 0)
if [ "${FUNDED:-0}" -ge "$AMOUNT" ]; then
  say "fund — already at $FUNDED, nothing to do"
else
  TOPUP=$(( AMOUNT - ${FUNDED:-0} ))
  say "fund — topping up $TOPUP to reach $AMOUNT"
  run --function-id ${MODULE}::escrow::fund --args address:$ESCROW u64:$TOPUP
fi

if [ "$PREPARE_ONLY" = "1" ]; then
  say "prepared — no root published"
  echo "  escrow       $ESCROW"
  echo "  funded_total $(view --function-id ${MODULE}::escrow::funded_total --args address:$ESCROW)"
  cat <<EOF

Connect the wallet, then publish the root for its address:

  ./setup-escrow.sh 0x<connected-address> $EVENT_ID $AMOUNT

EOF
  exit 0
fi

say "leaf for this claimant"
LEAF=$(view --function-id ${MODULE}::escrow::leaf_for \
       --args address:$CLAIMANT hex:${IDENT#0x} u64:$AMOUNT)
echo "leaf: $LEAF"

EXISTING=$(view --function-id ${MODULE}::escrow::root --args address:$ESCROW || echo "")
if echo "$EXISTING" | grep -q "0x"; then
  say "publish_root — a root already exists"
  echo "  on chain: $EXISTING"
  echo "  this leaf: $LEAF"
  echo ""
  echo "  A root is write-once. If those differ, this escrow was published for a"
  echo "  different address or amount - use a FRESH event id rather than trying"
  echo "  to correct this one."
else
  say "publish_root (single leaf, so root == leaf)"
  run --function-id ${MODULE}::escrow::publish_root --args address:$ESCROW hex:${LEAF#0x} u64:$AMOUNT
fi

say "state"
echo "  root         $(view --function-id ${MODULE}::escrow::root --args address:$ESCROW)"
echo "  root_total   $(view --function-id ${MODULE}::escrow::root_total --args address:$ESCROW)"
echo "  funded_total $(view --function-id ${MODULE}::escrow::funded_total --args address:$ESCROW)"
echo "  balance      $(view --function-id ${MODULE}::escrow::balance --args address:$ESCROW)"
echo "  is_claimed   $(view --function-id ${MODULE}::escrow::is_claimed --args address:$ESCROW hex:${LEAF#0x})"

cat <<EOF

Ready. In the page: set Event id to "$EVENT_ID", Amount to $AMOUNT, then
click "Derive escrow + leaf". Root and leaf above should match what it shows,
and is_claimed must be false.

Each run needs a FRESH event id - publish_root is write-once per escrow, and a
claimed leaf cannot be reclaimed. For the second wallet use e.g.
  ./setup-escrow.sh 0x<addr> wallet-check-2
EOF
