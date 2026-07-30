#!/usr/bin/env bash
#
# Deploy BatchDelegate, authorize it for an Anvil EOA with EIP-7702, and
# execute approve + transfer atomically from that EOA.
#
# Usage: ./utils/accounts/eip7702/deploy_7702.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev account #0 deploys the implementation and token.
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
# Anvil dev account #1 delegates its account and submits the batch.
ACCOUNT_KEY="${ACCOUNT_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
ACCOUNT=$(cast wallet address "$ACCOUNT_KEY")
RECIPIENT="${RECIPIENT:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil --hardfork prague')" >&2
    exit 1
fi

echo "==> Deploying the EIP-7702 batch implementation to chain $CHAIN_ID"
DEPLOY_OUTPUT=$(forge script \
    script/accounts/eip7702/DeployBatchDelegate.s.sol:DeployBatchDelegate \
    --rpc-url "$RPC_URL" --broadcast)
IMPLEMENTATION=$(echo "$DEPLOY_OUTPUT" | grep -Eo 'BATCH_DELEGATE: 0x[0-9a-fA-F]{40}' | awk '{print $2}')

TOKEN_OUTPUT=$(forge create src/signatures/PermitToken.sol:PermitToken \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast)
TOKEN=$(echo "$TOKEN_OUTPUT" | grep -Eo 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}')

if [ -z "$IMPLEMENTATION" ] || [ -z "$TOKEN" ]; then
    echo "error: could not parse deployed contract addresses" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/accounts/eip7702.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
{
    echo "BATCH_DELEGATE=$IMPLEMENTATION"
    echo "TOKEN=$TOKEN"
    echo "DELEGATED_ACCOUNT=$ACCOUNT"
} > "$DEPLOYMENT_FILE"

echo "    implementation: $IMPLEMENTATION"
echo "    token:          $TOKEN"
echo "    account:        $ACCOUNT"

MINT_AMOUNT=$(cast to-wei 1000)
APPROVE_AMOUNT=$(cast to-wei 250)
TRANSFER_AMOUNT=$(cast to-wei 75)

cast send "$TOKEN" "mint(address,uint256)" "$ACCOUNT" "$MINT_AMOUNT" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

APPROVE_DATA=$(cast calldata "approve(address,uint256)" "$RECIPIENT" "$APPROVE_AMOUNT")
TRANSFER_DATA=$(cast calldata "transfer(address,uint256)" "$RECIPIENT" "$TRANSFER_AMOUNT")

echo ""
echo "==> Authorizing BatchDelegate and executing approve + transfer"
cast send "$ACCOUNT" "executeBatch((address,uint256,bytes)[])" \
    "[($TOKEN,0,$APPROVE_DATA),($TOKEN,0,$TRANSFER_DATA)]" \
    --auth "$IMPLEMENTATION" \
    --rpc-url "$RPC_URL" --private-key "$ACCOUNT_KEY" > /dev/null

ACCOUNT_CODE=$(cast code "$ACCOUNT" --rpc-url "$RPC_URL")
ACCOUNT_BALANCE=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$ACCOUNT" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
RECIPIENT_BALANCE=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$RECIPIENT" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
ALLOWANCE=$(cast call "$TOKEN" "allowance(address,address)(uint256)" "$ACCOUNT" "$RECIPIENT" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
EXPECTED_CODE="0xef0100${IMPLEMENTATION#0x}"
EXPECTED_ACCOUNT_BALANCE=$(echo "$MINT_AMOUNT - $TRANSFER_AMOUNT" | bc)

echo ""
echo "==> Verifying"
FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
    actual=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
    if [ "$expected" = "$actual" ]; then
        echo "    PASS  $label"
    else
        echo "    FAIL  $label: expected $expected, got $actual"
        FAILURES=$((FAILURES + 1))
    fi
}

check "account contains the EIP-7702 designator" "$EXPECTED_CODE" "$ACCOUNT_CODE"
check "approve executed from the delegated account" "$APPROVE_AMOUNT" "$ALLOWANCE"
check "transfer credited the recipient" "$TRANSFER_AMOUNT" "$RECIPIENT_BALANCE"
check "transfer debited the delegated account" "$EXPECTED_ACCOUNT_BALANCE" "$ACCOUNT_BALANCE"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> EIP-7702 batch verified: all checks passed"
    echo "    deployment: $DEPLOYMENT_FILE"
else
    echo "==> EIP-7702 batch verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
