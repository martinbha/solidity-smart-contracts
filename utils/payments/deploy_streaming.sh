#!/usr/bin/env bash
#
# deploy_streaming.sh — deploy the payment streaming manager and walk a full
# salary stream lifecycle between Anvil accounts:
#
#   deployer (Anvil #0) opens a 30k STRM stream to alice (Anvil #1)
#     over 30 days with a 1-day cliff
#   before the cliff        → alice's withdrawable balance is 0
#   +10 days                → alice withdraws everything accrued (~1/3)
#   +5 more days            → deployer cancels: alice is paid the accrued
#                             remainder, deployer refunded the rest
#
# Verifies alice's total receipts plus the deployer's refund sum exactly to
# the original 30k deposit (the conservation invariant) and that the manager
# holds no stranded dust.
#
# Usage: ./utils/payments/deploy_streaming.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev accounts: #0 deployer/sender, #1 alice (public keys, local only).
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
ALICE_KEY="${ALICE_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying stream manager to chain $CHAIN_ID"
OUTPUT=$(forge script script/payments/DeployStreamManager.s.sol:DeployStreamManager \
    --rpc-url "$RPC_URL" --broadcast)

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }
TOKEN=$(parse_addr "STREAM_TOKEN")
MANAGER=$(parse_addr "STREAM_MANAGER")

if [ -z "$TOKEN" ] || [ -z "$MANAGER" ]; then
    echo "error: could not parse deploy addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/payments/streaming.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
STREAM_TOKEN=$TOKEN
STREAM_MANAGER=$MANAGER
EOF
echo "    token:   $TOKEN"
echo "    manager: $MANAGER"

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
ALICE=$(cast wallet address --private-key "$ALICE_KEY")
TOTAL=30000000000000000000000 # 30_000 STRM

DAY=86400
NOW=$(cast block latest -f timestamp --rpc-url "$RPC_URL")
START=$((NOW + 60))
CLIFF=$((START + DAY))
END=$((START + 30 * DAY))

advance() {
    cast rpc evm_increaseTime "$1" --rpc-url "$RPC_URL" > /dev/null
    cast rpc evm_mine --rpc-url "$RPC_URL" > /dev/null
}

balance_of() {
    cast call "$TOKEN" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC_URL" | awk '{print $1}'
}

echo ""
echo "==> Opening a 30k STRM / 30-day stream to alice (1-day cliff)"
cast send "$TOKEN" "approve(address,uint256)" "$MANAGER" "$TOTAL" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
STREAM_ID=$(cast call "$MANAGER" "nextStreamId()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$MANAGER" "createStream(address,address,uint256,uint256,uint256,uint256)" \
    "$ALICE" "$TOKEN" "$TOTAL" "$START" "$CLIFF" "$END" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
echo "    stream #$STREAM_ID opened"

DEPLOYER_AFTER_DEPOSIT=$(balance_of "$DEPLOYER")

PRE_CLIFF=$(cast call "$MANAGER" "balanceOf(uint256)(uint256)" "$STREAM_ID" --rpc-url "$RPC_URL" | awk '{print $1}')
echo "    withdrawable before cliff: $(cast from-wei "$PRE_CLIFF") STRM"

echo ""
echo "==> +10 days: alice withdraws everything accrued"
advance $((60 + 10 * DAY))
cast send "$MANAGER" "withdraw(uint256,uint256)" "$STREAM_ID" \
    "$(cast max-uint)" --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
MID_WITHDRAWN=$(balance_of "$ALICE")
echo "    alice withdrew $(cast from-wei "$MID_WITHDRAWN") STRM mid-stream"

echo ""
echo "==> +5 more days: deployer cancels the stream"
advance $((5 * DAY))
cast send "$MANAGER" "cancel(uint256)" "$STREAM_ID" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
echo "    stream cancelled at ~day 15"

echo ""
echo "==> Verifying"
FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}

ALICE_TOTAL=$(balance_of "$ALICE")
DEPLOYER_FINAL=$(balance_of "$DEPLOYER")
MANAGER_LEFT=$(balance_of "$MANAGER")
# bc: 18-decimal amounts exceed shell integer math.
REFUND=$(echo "$DEPLOYER_FINAL - $DEPLOYER_AFTER_DEPOSIT" | bc)

echo "    alice received  $(cast from-wei "$ALICE_TOTAL") STRM total"
echo "    deployer refund $(cast from-wei "$REFUND") STRM"

check "nothing withdrawable before cliff" "0" "$PRE_CLIFF"
check "alice withdrew a positive amount mid-stream" "1" "$(echo "$MID_WITHDRAWN > 0" | bc)"
check "cancel paid alice more than she had withdrawn" "1" "$(echo "$ALICE_TOTAL > $MID_WITHDRAWN" | bc)"
check "recipient + refund == deposit (conservation)" "1" \
    "$(echo "$ALICE_TOTAL + $REFUND == $TOTAL" | bc)"
check "no dust stranded in the manager" "0" "$MANAGER_LEFT"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Streaming verified: all checks passed"
else
    echo "==> Streaming verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
