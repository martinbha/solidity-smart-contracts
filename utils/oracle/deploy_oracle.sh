#!/usr/bin/env bash
#
# Deploy and exercise the optimistic oracle on a local Anvil chain:
#   1. settle an undisputed true claim and collect its insurance payout
#   2. dispute a false assertion, resolve truthfully, and award both bonds
#
# Usage: ./utils/oracle/deploy_oracle.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Public Anvil development keys only.
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
ALICE_KEY="${ALICE_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
BOB_KEY="${BOB_KEY:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"
RESOLVER_KEY="${RESOLVER_KEY:-0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil')" >&2
    exit 1
fi

ALICE=$(cast wallet address --private-key "$ALICE_KEY")
BOB=$(cast wallet address --private-key "$BOB_KEY")
export POLICYHOLDER="$ALICE"
export RESOLVER
RESOLVER=$(cast wallet address --private-key "$RESOLVER_KEY")

echo "==> Deploying optimistic oracle to chain $CHAIN_ID"
OUTPUT=$(forge script script/oracle/DeployOptimisticOracle.s.sol:DeployOptimisticOracle \
    --rpc-url "$RPC_URL" --broadcast --force)

parse_addr() {
    echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'
}

parse_uint() {
    echo "$OUTPUT" | grep -Eo "$1: [0-9]+" | awk '{print $2}'
}

BOND_TOKEN=$(parse_addr "BOND_TOKEN")
ORACLE=$(parse_addr "OPTIMISTIC_ORACLE")
POOL=$(parse_addr "INSURANCE_POOL")
BOND_AMOUNT=$(parse_uint "BOND_AMOUNT")
CHALLENGE_WINDOW=$(parse_uint "CHALLENGE_WINDOW")
INSURANCE_PAYOUT=$(parse_uint "INSURANCE_PAYOUT")

if [ -z "$BOND_TOKEN" ] || [ -z "$ORACLE" ] || [ -z "$POOL" ] || [ -z "$BOND_AMOUNT" ] \
    || [ -z "$CHALLENGE_WINDOW" ] || [ -z "$INSURANCE_PAYOUT" ]; then
    echo "error: could not parse deployment output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/oracle/oracle.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
{
    echo "BOND_TOKEN=$BOND_TOKEN"
    echo "OPTIMISTIC_ORACLE=$ORACLE"
    echo "INSURANCE_POOL=$POOL"
    echo "RESOLVER=$RESOLVER"
    echo "POLICYHOLDER=$POLICYHOLDER"
} > "$DEPLOYMENT_FILE"

echo "    bond token:     $BOND_TOKEN"
echo "    oracle:         $ORACLE"
echo "    insurance pool: $POOL"

PARTICIPANT_FUNDS=$(cast to-wei 1000)
cast send "$BOND_TOKEN" "mint(address,uint256)" "$ALICE" "$PARTICIPANT_FUNDS" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
cast send "$BOND_TOKEN" "mint(address,uint256)" "$BOB" "$PARTICIPANT_FUNDS" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
cast send "$BOND_TOKEN" "approve(address,uint256)" "$ORACLE" "$PARTICIPANT_FUNDS" \
    --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
cast send "$BOND_TOKEN" "approve(address,uint256)" "$ORACLE" "$PARTICIPANT_FUNDS" \
    --rpc-url "$RPC_URL" --private-key "$BOB_KEY" > /dev/null

INSURED_CLAIM=$(cast keccak "insured-event")
DISPUTED_CLAIM=$(cast keccak "disputed-event")

echo ""
echo "==> Settling an undisputed true assertion"
cast send "$ORACLE" "assertTruth(bytes32,bool)" "$INSURED_CLAIM" true \
    --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
if cast call "$POOL" "claim(bytes32)" "$INSURED_CLAIM" --from "$ALICE" \
    --rpc-url "$RPC_URL" > /dev/null 2>&1; then
    EARLY_PAYOUT_REVERTED=false
else
    EARLY_PAYOUT_REVERTED=true
fi

cast rpc evm_increaseTime "$((CHALLENGE_WINDOW + 1))" --rpc-url "$RPC_URL" > /dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" > /dev/null
cast send "$ORACLE" "settle(bytes32)" "$INSURED_CLAIM" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

ALICE_BEFORE_PAYOUT=$(cast call "$BOND_TOKEN" "balanceOf(address)(uint256)" "$ALICE" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$POOL" "claim(bytes32)" "$INSURED_CLAIM" \
    --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
ALICE_AFTER_PAYOUT=$(cast call "$BOND_TOKEN" "balanceOf(address)(uint256)" "$ALICE" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$ORACLE" "withdrawBond()" --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null

echo ""
echo "==> Resolving a disputed false assertion against the asserter"
cast send "$ORACLE" "assertTruth(bytes32,bool)" "$DISPUTED_CLAIM" false \
    --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
cast send "$ORACLE" "disputeAssertion(bytes32)" "$DISPUTED_CLAIM" \
    --rpc-url "$RPC_URL" --private-key "$BOB_KEY" > /dev/null
if cast call "$ORACLE" "settle(bytes32)" "$DISPUTED_CLAIM" --rpc-url "$RPC_URL" > /dev/null 2>&1; then
    DISPUTED_SETTLE_REVERTED=false
else
    DISPUTED_SETTLE_REVERTED=true
fi
cast send "$ORACLE" "resolve(bytes32,bool)" "$DISPUTED_CLAIM" true \
    --rpc-url "$RPC_URL" --private-key "$RESOLVER_KEY" > /dev/null

BOB_REWARD=$(cast call "$ORACLE" "withdrawableBonds(address)(uint256)" "$BOB" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$ORACLE" "withdrawBond()" --rpc-url "$RPC_URL" --private-key "$BOB_KEY" > /dev/null

TRUE_RESULT=$(cast call "$ORACLE" "getResult(bytes32)(bool,bool)" "$INSURED_CLAIM" \
    --rpc-url "$RPC_URL" | tr '\n' ' ' | xargs)
DISPUTED_RESULT=$(cast call "$ORACLE" "getResult(bytes32)(bool,bool)" "$DISPUTED_CLAIM" \
    --rpc-url "$RPC_URL" | tr '\n' ' ' | xargs)
ORACLE_BALANCE=$(cast call "$BOND_TOKEN" "balanceOf(address)(uint256)" "$ORACLE" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
ACCOUNTED_BALANCE=$(cast call "$ORACLE" "accountedBondBalance()(uint256)" \
    --rpc-url "$RPC_URL" | awk '{print $1}')

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
check "unresolved insurance payout reverted" "true" "$EARLY_PAYOUT_REVERTED"
check "undisputed assertion resolved true" "true true" "$TRUE_RESULT"
check "insurance paid the configured amount" "1" \
    "$(echo "$ALICE_AFTER_PAYOUT - $ALICE_BEFORE_PAYOUT == $INSURANCE_PAYOUT" | bc)"
check "disputed assertion could not settle optimistically" "true" "$DISPUTED_SETTLE_REVERTED"
check "resolver recorded true for the disputed claim" "true true" "$DISPUTED_RESULT"
check "honest disputer received both bonds" "$(echo "$BOND_AMOUNT * 2" | bc)" "$BOB_REWARD"
check "oracle token balance returned to zero" "0" "$ORACLE_BALANCE"
check "oracle accounting returned to zero" "0" "$ACCOUNTED_BALANCE"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Optimistic oracle verified: all checks passed"
    echo "    deployment: $DEPLOYMENT_FILE"
else
    echo "==> Optimistic oracle verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
