#!/usr/bin/env bash
#
# claim_merkle.sh — claim one airdrop allocation and verify it on-chain:
#
#   1. the recipient's token balance grows by exactly the tree amount
#   2. isClaimed(index) flips to true
#   3. a second claim of the same index reverts
#
# The broadcasting key acts as a relayer: it pays gas, but tokens go to the
# account proven in the tree — claim() is permissionless by design.
#
# Usage: ./utils/merkle/claim_merkle.sh [claim-index]   (default 0)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
export CLAIM_INDEX="${1:-0}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/merkle/airdrop.${CHAIN_ID}.env"
if [ ! -f "$DEPLOYMENT_FILE" ]; then
    echo "error: $DEPLOYMENT_FILE not found — run utils/merkle/deploy_merkle.sh first" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$DEPLOYMENT_FILE"
export MERKLE_DISTRIBUTOR

# Pull this claim's account/amount out of tree.json for verification.
CLAIM_OBJ=$(grep -o "{\"index\":${CLAIM_INDEX},[^}]*}" deployments/merkle/tree.json || true)
if [ -z "$CLAIM_OBJ" ]; then
    echo "error: claim index $CLAIM_INDEX not found in deployments/merkle/tree.json" >&2
    exit 1
fi
ACCOUNT=$(echo "$CLAIM_OBJ" | sed -E 's/.*"account":"(0x[0-9a-fA-F]{40})".*/\1/')
AMOUNT=$(echo "$CLAIM_OBJ" | sed -E 's/.*"amount":"([0-9]+)".*/\1/')

echo "==> Claiming index $CLAIM_INDEX for $ACCOUNT ($AMOUNT wei of AIR)"
BALANCE_BEFORE=$(cast call "$MERKLE_TOKEN" "balanceOf(address)(uint256)" "$ACCOUNT" --rpc-url "$RPC_URL" | awk '{print $1}')

forge script script/merkle/ClaimAirdrop.s.sol:ClaimAirdrop --rpc-url "$RPC_URL" --broadcast \
    | grep -E "CLAIMED_" || true

echo ""
echo "==> Verifying claim"
FAILURES=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "    PASS  $label: $actual"
    else
        echo "    FAIL  $label: expected $expected, got $actual"
        FAILURES=$((FAILURES + 1))
    fi
}

# 1. balance grew by exactly the tree amount (bc: values exceed 64-bit shell math)
BALANCE_AFTER=$(cast call "$MERKLE_TOKEN" "balanceOf(address)(uint256)" "$ACCOUNT" --rpc-url "$RPC_URL" | awk '{print $1}')
DELTA=$(echo "$BALANCE_AFTER - $BALANCE_BEFORE" | bc)
check "recipient balance delta" "$AMOUNT" "$DELTA"

# 2. bitmap marked
IS_CLAIMED=$(cast call "$MERKLE_DISTRIBUTOR" "isClaimed(uint256)(bool)" "$CLAIM_INDEX" --rpc-url "$RPC_URL")
check "isClaimed($CLAIM_INDEX)" "true" "$IS_CLAIMED"

# 3. double claim must revert
PROOF=$(echo "$CLAIM_OBJ" | sed -E 's/.*"proof":\[([^]]*)\].*/[\1]/' | tr -d '"')
if cast send "$MERKLE_DISTRIBUTOR" "claim(uint256,address,uint256,bytes32[])" \
    "$CLAIM_INDEX" "$ACCOUNT" "$AMOUNT" "$PROOF" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null 2>&1; then
    check "double claim reverts" "revert" "succeeded"
else
    check "double claim reverts" "revert" "revert"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Claim verified: all checks passed"
else
    echo "==> Claim verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
