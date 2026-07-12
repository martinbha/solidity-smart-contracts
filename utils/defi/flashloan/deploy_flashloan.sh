#!/usr/bin/env bash
#
# deploy_flashloan.sh — deploy the ERC-3156 flash lender and run one honest
# flash loan end to end:
#
#   deploy token + lender (0.09% fee) + good borrower; seed the pool with 1M
#   mint the borrower just the fee (a flash loan hands you principal, never
#     the fee), then have it flash-borrow 500k and repay principal + fee
#
# Verifies the pool grew by exactly the fee and the borrower ended flat —
# the loan was free liquidity that cost only the fee.
#
# Usage: ./utils/defi/flashloan/deploy_flashloan.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev account #0 (public key, local only).
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying flash lender to chain $CHAIN_ID"
OUTPUT=$(forge script script/defi/flashloan/DeployFlashLender.s.sol:DeployFlashLender \
    --rpc-url "$RPC_URL" --broadcast)

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }
TOKEN=$(parse_addr "FLASH_TOKEN")
LENDER=$(parse_addr "FLASH_LENDER")
BORROWER=$(parse_addr "GOOD_BORROWER")

if [ -z "$TOKEN" ] || [ -z "$LENDER" ] || [ -z "$BORROWER" ]; then
    echo "error: could not parse deploy addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/defi/flashloan.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
FLASH_TOKEN=$TOKEN
FLASH_LENDER=$LENDER
GOOD_BORROWER=$BORROWER
EOF
echo "    token:    $TOKEN"
echo "    lender:   $LENDER"
echo "    borrower: $BORROWER"

AMOUNT=500000000000000000000000 # 500k FLASH
FEE=$(cast call "$LENDER" "flashFee(address,uint256)(uint256)" "$TOKEN" "$AMOUNT" --rpc-url "$RPC_URL" | awk '{print $1}')

echo ""
echo "==> Running an honest flash loan of 500k (fee $(cast from-wei "$FEE") FLASH)"
# The borrower must own the fee up front — the loan only ever lends principal.
cast send "$TOKEN" "mint(address,uint256)" "$BORROWER" "$FEE" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

POOL_BEFORE=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$LENDER" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$BORROWER" "borrow(uint256,bytes)" "$AMOUNT" "0x" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
POOL_AFTER=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$LENDER" --rpc-url "$RPC_URL" | awk '{print $1}')
BORROWER_END=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$BORROWER" --rpc-url "$RPC_URL" | awk '{print $1}')

echo ""
echo "==> Verifying"
FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}

# bc: 18-decimal amounts exceed shell integer math.
check "pool grew by exactly the fee" "$FEE" "$(echo "$POOL_AFTER - $POOL_BEFORE" | bc)"
check "borrower ended flat (fee consumed)" "0" "$BORROWER_END"
echo "    pool: $(cast from-wei "$POOL_BEFORE") -> $(cast from-wei "$POOL_AFTER") FLASH"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Flash lender verified: all checks passed"
else
    echo "==> Flash lender verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
