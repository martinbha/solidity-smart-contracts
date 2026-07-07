#!/usr/bin/env bash
#
# deploy_merkle.sh — deploy the Merkle airdrop (token + distributor).
#
# Generates the tree first if deployments/merkle/tree.json doesn't exist,
# deploys AirdropToken + MerkleDistributor with the tree's root, funds the
# distributor with the exact total owed, and records the addresses in
# deployments/merkle/airdrop.<chain-id>.env for claim_merkle.sh.
#
# Config comes from .env at the repo root; defaults target local Anvil.
#
# Usage: ./utils/merkle/deploy_merkle.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

if [ ! -f deployments/merkle/tree.json ]; then
    ./utils/merkle/generate_tree.sh
fi

echo "==> Deploying Merkle airdrop to chain $CHAIN_ID via $RPC_URL"

OUTPUT=$(forge script script/merkle/DeployMerkleAirdrop.s.sol:DeployMerkleAirdrop \
    --rpc-url "$RPC_URL" --broadcast)
echo "$OUTPUT"

TOKEN=$(echo "$OUTPUT" | grep -Eo 'MERKLE_TOKEN: 0x[0-9a-fA-F]{40}' | awk '{print $2}')
DISTRIBUTOR=$(echo "$OUTPUT" | grep -Eo 'MERKLE_DISTRIBUTOR: 0x[0-9a-fA-F]{40}' | awk '{print $2}')

if [ -z "$TOKEN" ] || [ -z "$DISTRIBUTOR" ]; then
    echo "error: could not parse addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/merkle/airdrop.${CHAIN_ID}.env"
cat > "$DEPLOYMENT_FILE" <<EOF
MERKLE_TOKEN=$TOKEN
MERKLE_DISTRIBUTOR=$DISTRIBUTOR
EOF

# The distributor must hold exactly what the tree owes.
EXPECTED=$(grep -Eo '"totalAmount":"[0-9]+"' deployments/merkle/tree.json | grep -Eo '[0-9]+')
FUNDED=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$DISTRIBUTOR" --rpc-url "$RPC_URL" | awk '{print $1}')

echo ""
echo "==> Deployed"
echo "    token:              $TOKEN"
echo "    distributor:        $DISTRIBUTOR"
echo "    distributor funded: $FUNDED (expected $EXPECTED)"
echo "    recorded in:        $DEPLOYMENT_FILE"

if [ "$FUNDED" != "$EXPECTED" ]; then
    echo "error: distributor balance does not match the tree total" >&2
    exit 1
fi
