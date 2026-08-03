#!/usr/bin/env bash
#
# Deploy and exercise the ERC-6551 token-bound account example on Anvil:
#   1. deploy the registry, account implementation, profile NFT, and demo token
#   2. mint a profile to Alice and verify its predicted account address
#   3. fund the account with ETH and ERC-20 tokens
#   4. transfer the profile to Bob and prove control follows the NFT
#   5. prove Alice lost access while Bob can send both assets from the account
#
# Usage: ./utils/nft/erc6551/deploy_6551.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Public Anvil development keys only.
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
ALICE_KEY="${ALICE_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
BOB_KEY="${BOB_KEY:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil')" >&2
    exit 1
fi

ALICE=$(cast wallet address --private-key "$ALICE_KEY")
BOB=$(cast wallet address --private-key "$BOB_KEY")
RECIPIENT=$(cast wallet address --private-key "$PRIVATE_KEY")
export PROFILE_OWNER="$ALICE"

echo "==> Deploying ERC-6551 example to chain $CHAIN_ID"
OUTPUT=$(forge script script/nft/erc6551/DeployTokenBound.s.sol:DeployTokenBound \
    --rpc-url "$RPC_URL" --broadcast --force)

parse_addr() {
    echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'
}

REGISTRY=$(parse_addr "ERC6551_REGISTRY")
IMPLEMENTATION=$(parse_addr "TOKEN_BOUND_IMPLEMENTATION")
PROFILE=$(parse_addr "PROFILE_NFT")
ASSET=$(parse_addr "PROFILE_ASSET")
ACCOUNT=$(parse_addr "TOKEN_BOUND_ACCOUNT")
TOKEN_ID=$(echo "$OUTPUT" | grep -Eo "PROFILE_TOKEN_ID: [0-9]+" | awk '{print $2}')

if [ -z "$REGISTRY" ] || [ -z "$IMPLEMENTATION" ] || [ -z "$PROFILE" ] \
    || [ -z "$ASSET" ] || [ -z "$ACCOUNT" ] || [ -z "$TOKEN_ID" ]; then
    echo "error: could not parse deployment output" >&2
    exit 1
fi

OUT_DIR="${DEPLOYMENT_DIR:-deployments/nft/erc6551}"
mkdir -p "$OUT_DIR"
DEPLOYMENT_FILE="$OUT_DIR/erc6551.${CHAIN_ID}.env"
{
    echo "ERC6551_REGISTRY=$REGISTRY"
    echo "TOKEN_BOUND_IMPLEMENTATION=$IMPLEMENTATION"
    echo "PROFILE_NFT=$PROFILE"
    echo "PROFILE_ASSET=$ASSET"
    echo "PROFILE_TOKEN_ID=$TOKEN_ID"
    echo "TOKEN_BOUND_ACCOUNT=$ACCOUNT"
} > "$DEPLOYMENT_FILE"

echo "    registry:       $REGISTRY"
echo "    implementation: $IMPLEMENTATION"
echo "    profile NFT:    $PROFILE"
echo "    profile token:  $TOKEN_ID"
echo "    bound account:  $ACCOUNT"

ACCOUNT_SALT="0x0000000000000000000000000000000000000000000000000000000000000000"
PREDICTED=$(cast call "$REGISTRY" \
    "account(address,bytes32,uint256,address,uint256)(address)" \
    "$IMPLEMENTATION" "$ACCOUNT_SALT" "$CHAIN_ID" "$PROFILE" "$TOKEN_ID" \
    --rpc-url "$RPC_URL")

echo ""
echo "==> Funding the counterparty inventory"
cast send "$ACCOUNT" --value 2ether --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
ASSET_FUNDS=$(cast to-wei 100)
ASSET_SEND=$(cast to-wei 25)
cast send "$ASSET" "mint(address,uint256)" "$ACCOUNT" "$ASSET_FUNDS" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

echo ""
echo "==> Transferring the profile and exercising its account"
cast send "$PROFILE" "safeTransferFrom(address,address,uint256)" "$ALICE" "$BOB" "$TOKEN_ID" \
    --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null

TRANSFER_DATA=$(cast calldata "transfer(address,uint256)" "$RECIPIENT" "$ASSET_SEND")
if cast call "$ACCOUNT" "execute(address,uint256,bytes)(bytes)" "$ASSET" 0 "$TRANSFER_DATA" \
    --from "$ALICE" --rpc-url "$RPC_URL" > /dev/null 2>&1; then
    OLD_OWNER_REVERTED=false
else
    OLD_OWNER_REVERTED=true
fi

cast send "$ACCOUNT" "execute(address,uint256,bytes)(bytes)" "$ASSET" 0 "$TRANSFER_DATA" \
    --rpc-url "$RPC_URL" --private-key "$BOB_KEY" > /dev/null
RECIPIENT_ETH_BEFORE=$(cast balance "$RECIPIENT" --rpc-url "$RPC_URL")
cast send "$ACCOUNT" "execute(address,uint256,bytes)(bytes)" "$RECIPIENT" 0.5ether 0x \
    --rpc-url "$RPC_URL" --private-key "$BOB_KEY" > /dev/null
RECIPIENT_ETH_AFTER=$(cast balance "$RECIPIENT" --rpc-url "$RPC_URL")

CURRENT_OWNER=$(cast call "$ACCOUNT" "owner()(address)" --rpc-url "$RPC_URL")
ACCOUNT_ASSET_BALANCE=$(cast call "$ASSET" "balanceOf(address)(uint256)" "$ACCOUNT" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
RECIPIENT_ASSET_BALANCE=$(cast call "$ASSET" "balanceOf(address)(uint256)" "$RECIPIENT" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
ACCOUNT_ETH_BALANCE=$(cast balance "$ACCOUNT" --rpc-url "$RPC_URL")
ACCOUNT_STATE=$(cast call "$ACCOUNT" "state()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')

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

lower() {
    tr '[:upper:]' '[:lower:]'
}

echo ""
echo "==> Verifying"
check "prediction matches deployed account" "$(echo "$ACCOUNT" | lower)" "$(echo "$PREDICTED" | lower)"
check "ownership follows the transferred NFT" "$(echo "$BOB" | lower)" "$(echo "$CURRENT_OWNER" | lower)"
check "previous owner lost execution access" "true" "$OLD_OWNER_REVERTED"
check "account retained 75 demo tokens" "$(cast to-wei 75)" "$ACCOUNT_ASSET_BALANCE"
check "new owner sent 25 demo tokens" "$ASSET_SEND" "$RECIPIENT_ASSET_BALANCE"
check "account retained 1.5 ETH" "$(cast to-wei 1.5)" "$ACCOUNT_ETH_BALANCE"
check "new owner sent 0.5 ETH" "$(cast to-wei 0.5)" "$((RECIPIENT_ETH_AFTER - RECIPIENT_ETH_BEFORE))"
check "two successful account calls updated state" "2" "$ACCOUNT_STATE"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> ERC-6551 example verified: control and inventory followed the NFT"
    echo "    deployment: $DEPLOYMENT_FILE"
else
    echo "==> ERC-6551 verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
