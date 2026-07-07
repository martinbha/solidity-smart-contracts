#!/usr/bin/env bash
#
# deploy_fleet.sh — initial deploy of the beacon-proxied Billboard fleet.
#
# Deploys the V1 implementation, the BillboardFactory (which spawns the shared
# UpgradeableBeacon), and three sample billboard instances. Records everything
# in deployments/upgradeable/fleet.<chain-id>.env for upgrade_fleet.sh.
#
# Config comes from .env at the repo root (see .env.example). With no .env it
# falls back to a local Anvil node and Anvil's well-known account #0.
#
# Usage: ./utils/upgradeable/beacon/deploy_fleet.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

# Defaults: local Anvil node, Anvil account #0 (publicly known dev key).
export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying Billboard fleet (V1 + factory + beacon + 3 instances) to chain $CHAIN_ID"

OUTPUT=$(forge script script/upgradeable/beacon/DeployBillboardFleet.s.sol:DeployBillboardFleet \
    --rpc-url "$RPC_URL" --broadcast)
echo "$OUTPUT"

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }

FACTORY=$(parse_addr "FLEET_FACTORY")
BEACON=$(parse_addr "FLEET_BEACON")
IMPL=$(parse_addr "FLEET_IMPLEMENTATION")
INSTANCE_0=$(parse_addr "FLEET_INSTANCE_0")
INSTANCE_1=$(parse_addr "FLEET_INSTANCE_1")
INSTANCE_2=$(parse_addr "FLEET_INSTANCE_2")

if [ -z "$FACTORY" ] || [ -z "$INSTANCE_2" ]; then
    echo "error: could not parse fleet addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/upgradeable/fleet.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
FLEET_FACTORY=$FACTORY
FLEET_BEACON=$BEACON
FLEET_IMPLEMENTATION=$IMPL
FLEET_INSTANCES=$INSTANCE_0,$INSTANCE_1,$INSTANCE_2
EOF

echo ""
echo "==> Fleet deployed"
echo "    factory:            $FACTORY"
echo "    beacon (shared):    $BEACON"
echo "    implementation V1:  $IMPL"

for INSTANCE in "$INSTANCE_0" "$INSTANCE_1" "$INSTANCE_2"; do
    VERSION=$(cast call "$INSTANCE" "version()(string)" --rpc-url "$RPC_URL")
    MESSAGE=$(cast call "$INSTANCE" "message()(string)" --rpc-url "$RPC_URL")
    echo "    instance $INSTANCE  version=$VERSION message=$MESSAGE"
done

COUNT=$(cast call "$FACTORY" "billboardCount()(uint256)" --rpc-url "$RPC_URL")
echo "    fleet size:         $COUNT"
echo "    recorded in:        $DEPLOYMENT_FILE"
