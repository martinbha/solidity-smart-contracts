#!/usr/bin/env bash
#
# upgrade_fleet.sh — upgrade the ENTIRE billboard fleet with one transaction,
# then verify on-chain:
#
#   1. every instance now reports version() == "2"       (one tx, all flipped)
#   2. every instance kept its own message                (state survival)
#   3. the shared beacon points at the V2 implementation
#   4. V2 storage works: setMessage bumps updateCount/lastEditor
#   5. instances created AFTER the upgrade are born on V2
#
# Reads the fleet recorded by deploy_fleet.sh from
# deployments/upgradeable/fleet.<chain-id>.env.
#
# Usage: ./utils/upgradeable/beacon/upgrade_fleet.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/upgradeable/fleet.${CHAIN_ID}.env"
if [ ! -f "$DEPLOYMENT_FILE" ]; then
    echo "error: $DEPLOYMENT_FILE not found — run utils/upgradeable/beacon/deploy_fleet.sh first" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$DEPLOYMENT_FILE"
export FLEET_FACTORY

IFS=',' read -r -a INSTANCES <<< "$FLEET_INSTANCES"
echo "==> Upgrading fleet of ${#INSTANCES[@]} instances via factory $FLEET_FACTORY (chain $CHAIN_ID)"

# Snapshot every instance's message before the upgrade.
MESSAGES_BEFORE=()
for INSTANCE in "${INSTANCES[@]}"; do
    MESSAGES_BEFORE+=("$(cast call "$INSTANCE" "message()(string)" --rpc-url "$RPC_URL")")
done

OUTPUT=$(forge script script/upgradeable/beacon/UpgradeBillboardFleet.s.sol:UpgradeBillboardFleet \
    --rpc-url "$RPC_URL" --broadcast)
echo "$OUTPUT"
NEW_IMPL=$(echo "$OUTPUT" | grep -Eo 'FLEET_IMPLEMENTATION_V2: 0x[0-9a-fA-F]{40}' | awk '{print $2}')

echo ""
echo "==> Verifying fleet upgrade"
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

# 1 + 2: one transaction flipped every instance, state intact
for i in "${!INSTANCES[@]}"; do
    INSTANCE="${INSTANCES[$i]}"
    VERSION=$(cast call "$INSTANCE" "version()(string)" --rpc-url "$RPC_URL")
    check "instance $i version() upgraded" '"2"' "$VERSION"
    MESSAGE=$(cast call "$INSTANCE" "message()(string)" --rpc-url "$RPC_URL")
    check "instance $i message() preserved" "${MESSAGES_BEFORE[$i]}" "$MESSAGE"
done

# 3: the shared beacon points at V2
BEACON_IMPL=$(cast call "$FLEET_BEACON" "implementation()(address)" --rpc-url "$RPC_URL")
check "beacon implementation() updated" "$NEW_IMPL" "$BEACON_IMPL"

# 4: V2's appended storage is live on an upgraded instance
TARGET="${INSTANCES[0]}"
COUNT_BEFORE=$(cast call "$TARGET" "updateCount()(uint256)" --rpc-url "$RPC_URL")
cast send "$TARGET" "setMessage(string)" "fleet upgraded to v2" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
COUNT_AFTER=$(cast call "$TARGET" "updateCount()(uint256)" --rpc-url "$RPC_URL")
check "updateCount() incremented" "$((COUNT_BEFORE + 1))" "$COUNT_AFTER"

SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")
LAST_EDITOR=$(cast call "$TARGET" "lastEditor()(address)" --rpc-url "$RPC_URL")
check "lastEditor() recorded" "$SENDER" "$LAST_EDITOR"

# 5: instances created after the upgrade are born on V2
SALT=$(printf '0x%064x' "$(date +%s)")
cast send "$FLEET_FACTORY" "createBillboard(string,bytes32)" "born on v2" "$SALT" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
FLEET_SIZE=$(cast call "$FLEET_FACTORY" "billboardCount()(uint256)" --rpc-url "$RPC_URL")
NEWBORN=$(cast call "$FLEET_FACTORY" "billboardAt(uint256)(address)" "$((FLEET_SIZE - 1))" --rpc-url "$RPC_URL")
NEWBORN_VERSION=$(cast call "$NEWBORN" "version()(string)" --rpc-url "$RPC_URL")
check "post-upgrade instance born on V2" '"2"' "$NEWBORN_VERSION"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Fleet upgrade verified: all checks passed (${#INSTANCES[@]} instances + 1 newborn)"
else
    echo "==> Fleet upgrade verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
