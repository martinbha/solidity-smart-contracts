#!/usr/bin/env bash
#
# Deploy the EIP-1153 examples, run a settled and an unsettled flash-accounting
# session, and compare transient versus persistent reentrancy-guard gas.
#
# Usage: ./utils/evm/transient/deploy_transient.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev account #0. Public local-development key only.
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil --hardfork osaka')" >&2
    exit 1
fi

echo "==> Deploying transient-storage examples to chain $CHAIN_ID"
OUTPUT=$(forge script script/evm/transient/DeployTransient.s.sol:DeployTransient \
    --rpc-url "$RPC_URL" --broadcast --force)

parse_addr() {
    echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'
}

TRANSIENT_VAULT=$(parse_addr "TRANSIENT_VAULT")
STORAGE_VAULT=$(parse_addr "STORAGE_VAULT")
ACCOUNTANT=$(parse_addr "FLASH_ACCOUNTANT")
TOKEN=$(parse_addr "TOKEN")
DEMO=$(parse_addr "FLASH_DEMO")

if [ -z "$TRANSIENT_VAULT" ] || [ -z "$STORAGE_VAULT" ] || [ -z "$ACCOUNTANT" ] \
    || [ -z "$TOKEN" ] || [ -z "$DEMO" ]; then
    echo "error: could not parse deployed contract addresses" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/evm/transient.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
{
    echo "TRANSIENT_VAULT=$TRANSIENT_VAULT"
    echo "STORAGE_VAULT=$STORAGE_VAULT"
    echo "FLASH_ACCOUNTANT=$ACCOUNTANT"
    echo "TOKEN=$TOKEN"
    echo "FLASH_DEMO=$DEMO"
} > "$DEPLOYMENT_FILE"

echo "    transient vault: $TRANSIENT_VAULT"
echo "    storage vault:   $STORAGE_VAULT"
echo "    accountant:      $ACCOUNTANT"
echo "    token:           $TOKEN"
echo "    demo callback:   $DEMO"

AMOUNT=$(cast to-wei 100)
BALANCE_BEFORE=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$ACCOUNTANT" \
    --rpc-url "$RPC_URL" | awk '{print $1}')

echo ""
echo "==> Running a take-and-settle session"
cast send "$DEMO" "run(uint256,bool)" "$AMOUNT" true \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

BALANCE_AFTER=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$ACCOUNTANT" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
LOCKER=$(cast call "$ACCOUNTANT" "currentLocker()(address)" --rpc-url "$RPC_URL")
DEBT_COUNT=$(cast call "$ACCOUNTANT" "outstandingDebtCount()(uint256)" \
    --rpc-url "$RPC_URL" | awk '{print $1}')

echo ""
echo "==> Confirming an unsettled session reverts"
if cast call "$DEMO" "run(uint256,bool)" "$AMOUNT" false --rpc-url "$RPC_URL" > /dev/null 2>&1; then
    UNSETTLED_REVERTED=false
else
    UNSETTLED_REVERTED=true
fi

TRANSIENT_GAS=$(cast estimate "$TRANSIENT_VAULT" "guardedNoop()" --rpc-url "$RPC_URL")
STORAGE_GAS=$(cast estimate "$STORAGE_VAULT" "guardedNoop()" --rpc-url "$RPC_URL")

echo ""
echo "==> Gas comparison"
echo "    transient guard: $TRANSIENT_GAS gas"
echo "    storage guard:   $STORAGE_GAS gas"
echo "    saved:           $((STORAGE_GAS - TRANSIENT_GAS)) gas"

FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "    PASS  $label"
    else
        echo "    FAIL  $label: expected $expected, got $actual"
        FAILURES=$((FAILURES + 1))
    fi
}

echo ""
echo "==> Verifying"
check "settled session conserved tokens" "$BALANCE_BEFORE" "$BALANCE_AFTER"
check "lock cleared after settlement" "0x0000000000000000000000000000000000000000" "$LOCKER"
check "debt count returned to zero" "0" "$DEBT_COUNT"
check "unsettled session reverted" "true" "$UNSETTLED_REVERTED"
check "transient guard used less gas" "true" "$([ "$TRANSIENT_GAS" -lt "$STORAGE_GAS" ] && echo true || echo false)"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Transient storage verified: all checks passed"
    echo "    deployment: $DEPLOYMENT_FILE"
else
    echo "==> Transient storage verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
