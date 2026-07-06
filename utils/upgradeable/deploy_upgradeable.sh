#!/usr/bin/env bash
#
# deploy_upgradeable.sh — initial deploy of the Billboard UUPS contract.
#
# Deploys the V1 implementation + ERC1967 proxy (initialized atomically) and
# records the addresses in deployments/upgradeable/billboard.<chain-id>.env
# for later use by upgrade_upgradeable.sh.
#
# Config comes from .env at the repo root (see .env.example). With no .env it
# falls back to a local Anvil node and Anvil's well-known account #0 — start
# one with `anvil` in another terminal and this script just works.
#
# Usage: ./utils/upgradeable/deploy_upgradeable.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

# Defaults: local Anvil node, Anvil account #0 (publicly known key — never
# holds real funds, safe to hardcode for local development only).
export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
export INITIAL_MESSAGE="${INITIAL_MESSAGE:-gm, world}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying Billboard (V1 + proxy) to chain $CHAIN_ID via $RPC_URL"

OUTPUT=$(forge script script/upgradeable/DeployBillboard.s.sol:DeployBillboard \
    --rpc-url "$RPC_URL" --broadcast)
echo "$OUTPUT"

PROXY=$(echo "$OUTPUT" | grep -Eo 'BILLBOARD_PROXY: 0x[0-9a-fA-F]{40}' | awk '{print $2}')
IMPL=$(echo "$OUTPUT" | grep -Eo 'BILLBOARD_IMPLEMENTATION: 0x[0-9a-fA-F]{40}' | awk '{print $2}')

if [ -z "$PROXY" ]; then
    echo "error: could not parse proxy address from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/upgradeable/billboard.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
BILLBOARD_PROXY=$PROXY
BILLBOARD_IMPLEMENTATION=$IMPL
EOF

MESSAGE=$(cast call "$PROXY" "message()(string)" --rpc-url "$RPC_URL")
VERSION=$(cast call "$PROXY" "version()(string)" --rpc-url "$RPC_URL")

echo ""
echo "==> Deployed"
echo "    proxy (permanent address):  $PROXY"
echo "    implementation (V1):        $IMPL"
echo "    version:                    $VERSION"
echo "    message:                    $MESSAGE"
echo "    recorded in:                $DEPLOYMENT_FILE"
