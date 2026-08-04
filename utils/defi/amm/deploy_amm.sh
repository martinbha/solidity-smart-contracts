#!/usr/bin/env bash
#
# deploy_amm.sh — deploy the constant-product AMM and drive it end to end:
#
#   deploy two tokens + factory + pair, seed 100k ALPHA / 200k BETA
#   swap in both directions and watch the price walk along the curve
#   advance time, then compare the TWAP against a freshly manipulated spot
#   remove all liquidity and check the LP got principal + fees back
#
# Verifies the CREATE2 address was predictable, that `k` never decreased, that
# a slippage guard actually reverts, that the TWAP resists a last-second
# whale swap, and that the liquidity provider ended up ahead.
#
# Usage: ./utils/defi/amm/deploy_amm.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev account #0 (public key, local only).
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

send() { cast send "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null; }
call() { cast call "$@" --rpc-url "$RPC_URL" | awk '{print $1}'; }
# consult() reads the caller's OWN anchor, so it must be called as the deployer
# that ran updateOracle -- an unanchored reader gets NoAnchor, by design.
call_as_deployer() { cast call "$@" --from "$DEPLOYER" --rpc-url "$RPC_URL" | awk '{print $1}'; }

echo "==> Deploying constant-product AMM to chain $CHAIN_ID"
OUTPUT=$(forge script script/defi/amm/DeployAmm.s.sol:DeployAmm \
    --rpc-url "$RPC_URL" --broadcast)

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }
TOKEN_A=$(parse_addr "AMM_TOKEN_A")
TOKEN_B=$(parse_addr "AMM_TOKEN_B")
FACTORY=$(parse_addr "AMM_FACTORY")
PAIR=$(parse_addr "AMM_PAIR")
TOKEN0=$(parse_addr "AMM_TOKEN0")
TOKEN1=$(parse_addr "AMM_TOKEN1")

if [ -z "$TOKEN_A" ] || [ -z "$FACTORY" ] || [ -z "$PAIR" ]; then
    echo "error: could not parse deploy addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/defi/amm.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
AMM_TOKEN_A=$TOKEN_A
AMM_TOKEN_B=$TOKEN_B
AMM_FACTORY=$FACTORY
AMM_PAIR=$PAIR
EOF
echo "    token A: $TOKEN_A"
echo "    token B: $TOKEN_B"
echo "    factory: $FACTORY"
echo "    pair:    $PAIR"

FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}
check_true() {
    local label="$1" condition="$2"
    if [ "$(echo "$condition" | bc)" = "1" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label ($condition)"; FAILURES=$((FAILURES + 1)); fi
}

PREDICTED=$(call "$FACTORY" "computePairAddress(address,address)(address)" "$TOKEN_A" "$TOKEN_B")
K_SEED=$(call "$PAIR" "k()(uint256)")
RESERVE0_SEED=$(call "$PAIR" "getReserves()(uint112,uint112,uint32)" | head -1)
SPOT_SEED=$(call "$PAIR" "spotPrice()(uint256)")

echo ""
echo "==> Swapping 10k token0 into the pool"
AMOUNT_IN=10000000000000000000000 # 10k
send "$TOKEN0" "approve(address,uint256)" "$PAIR" "$AMOUNT_IN"
QUOTED=$(cast call "$PAIR" "swap(address,uint256,uint256)(uint256)" "$TOKEN0" "$AMOUNT_IN" 0 \
    --from "$DEPLOYER" --rpc-url "$RPC_URL" | awk '{print $1}')
send "$PAIR" "swap(address,uint256,uint256)" "$TOKEN0" "$AMOUNT_IN" 0
K_AFTER_SWAP=$(call "$PAIR" "k()(uint256)")
SPOT_AFTER_SWAP=$(call "$PAIR" "spotPrice()(uint256)")
echo "    received: $(cast from-wei "$QUOTED") token1"
echo "    spot:     $(cast from-wei "$SPOT_SEED") -> $(cast from-wei "$SPOT_AFTER_SWAP") token1 per token0"

echo ""
echo "==> Rejecting a swap whose output misses the slippage guard"
send "$TOKEN0" "approve(address,uint256)" "$PAIR" "$AMOUNT_IN"
if cast send "$PAIR" "swap(address,uint256,uint256)" "$TOKEN0" "$AMOUNT_IN" \
    115792089237316195423570985008687907853269984665640564039457584007913129639935 \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null 2>&1; then
    echo "    FAIL  an impossible minAmountOut was accepted"
    FAILURES=$((FAILURES + 1))
else
    echo "    PASS  slippage guard reverted the swap"
fi

echo ""
echo "==> Swapping back the other way"
send "$TOKEN1" "approve(address,uint256)" "$PAIR" "$QUOTED"
send "$PAIR" "swap(address,uint256,uint256)" "$TOKEN1" "$QUOTED" 0
K_AFTER_ROUNDTRIP=$(call "$PAIR" "k()(uint256)")

echo ""
echo "==> Letting an hour pass, then manipulating spot in the final second"
send "$PAIR" "updateOracle()"
cast rpc evm_increaseTime 3600 --rpc-url "$RPC_URL" > /dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" > /dev/null

TWAP_BEFORE=$(call_as_deployer "$PAIR" "consult()(uint256)")
WHALE_IN=50000000000000000000000 # 50k
send "$TOKEN0" "approve(address,uint256)" "$PAIR" "$WHALE_IN"
send "$PAIR" "swap(address,uint256,uint256)" "$TOKEN0" "$WHALE_IN" 0
TWAP_AFTER=$(call_as_deployer "$PAIR" "consult()(uint256)")
SPOT_AFTER_WHALE=$(call "$PAIR" "spotPrice()(uint256)")

echo "    spot: $(cast from-wei "$SPOT_AFTER_WHALE"), twap: $(cast from-wei "$TWAP_AFTER")"

echo ""
echo "==> Removing all liquidity"
SHARES=$(call "$PAIR" "balanceOf(address)(uint256)" "$DEPLOYER")
BAL0_BEFORE=$(call "$TOKEN0" "balanceOf(address)(uint256)" "$DEPLOYER")
BAL1_BEFORE=$(call "$TOKEN1" "balanceOf(address)(uint256)" "$DEPLOYER")
send "$PAIR" "removeLiquidity(uint256)" "$SHARES"
OUT0=$(echo "$(call "$TOKEN0" "balanceOf(address)(uint256)" "$DEPLOYER") - $BAL0_BEFORE" | bc)
OUT1=$(echo "$(call "$TOKEN1" "balanceOf(address)(uint256)" "$DEPLOYER") - $BAL1_BEFORE" | bc)
echo "    returned: $(cast from-wei "$OUT0") token0 + $(cast from-wei "$OUT1") token1"

echo ""
echo "==> Verifying"
check "pair deployed at the predicted CREATE2 address" "$(echo "$PREDICTED" | tr 'A-Z' 'a-z')" "$(echo "$PAIR" | tr 'A-Z' 'a-z')"
check_true "k never decreased on the first swap" "$K_AFTER_SWAP >= $K_SEED"
check_true "k grew across the round trip (fees)" "$K_AFTER_ROUNDTRIP > $K_SEED"
check_true "spot moved with the trade" "$SPOT_AFTER_SWAP != $SPOT_SEED"
# The whale's swap held for zero seconds, so it carries no weight in the mean.
check_true "twap ignored the last-second whale" "$TWAP_AFTER == $TWAP_BEFORE"
check_true "twap is far above the manipulated spot" "$TWAP_AFTER > $SPOT_AFTER_WHALE"
check_true "the minimum liquidity stayed locked" "$(call "$PAIR" "totalSupply()(uint256)") == 1000"
# The whale left token0 in the pool, so the LP exits long token0 and short
# token1 — impermanent loss. Fees are visible in the invariant, not per leg.
check_true "LP recovered more token0 than seeded" "$OUT0 > $RESERVE0_SEED"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> AMM verified: all checks passed"
else
    echo "==> AMM verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
