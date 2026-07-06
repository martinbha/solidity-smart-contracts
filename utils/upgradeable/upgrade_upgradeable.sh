#!/usr/bin/env bash
#
# upgrade_upgradeable.sh — upgrade the deployed Billboard proxy to V2, then
# verify the upgrade on-chain:
#
#   1. state survival:  message() returns the same text as before the upgrade
#   2. new logic live:  version() flips from "1" to "2"
#   3. new storage:     setMessage() now bumps updateCount and lastEditor
#
# Reads the proxy address recorded by deploy_upgradeable.sh from
# deployments/upgradeable/billboard.<chain-id>.env.
#
# Usage: ./utils/upgradeable/upgrade_upgradeable.sh

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

DEPLOYMENT_FILE="deployments/upgradeable/billboard.${CHAIN_ID}.env"
if [ ! -f "$DEPLOYMENT_FILE" ]; then
    echo "error: $DEPLOYMENT_FILE not found — run utils/upgradeable/deploy_upgradeable.sh first" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$DEPLOYMENT_FILE"
export BILLBOARD_PROXY

echo "==> Upgrading Billboard proxy $BILLBOARD_PROXY on chain $CHAIN_ID"

MESSAGE_BEFORE=$(cast call "$BILLBOARD_PROXY" "message()(string)" --rpc-url "$RPC_URL")
VERSION_BEFORE=$(cast call "$BILLBOARD_PROXY" "version()(string)" --rpc-url "$RPC_URL")
echo "    before: version=$VERSION_BEFORE message=$MESSAGE_BEFORE"

forge script script/upgradeable/UpgradeBillboard.s.sol:UpgradeBillboard \
    --rpc-url "$RPC_URL" --broadcast

echo ""
echo "==> Verifying upgrade"
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

# 1. new logic is live
VERSION_AFTER=$(cast call "$BILLBOARD_PROXY" "version()(string)" --rpc-url "$RPC_URL")
check "version() upgraded" '"2"' "$VERSION_AFTER"

# 2. V1 state survived the upgrade
MESSAGE_AFTER=$(cast call "$BILLBOARD_PROXY" "message()(string)" --rpc-url "$RPC_URL")
check "message() preserved" "$MESSAGE_BEFORE" "$MESSAGE_AFTER"

# 3. V2's appended storage works: setMessage now tracks edits
COUNT_BEFORE=$(cast call "$BILLBOARD_PROXY" "updateCount()(uint256)" --rpc-url "$RPC_URL")
cast send "$BILLBOARD_PROXY" "setMessage(string)" "upgraded to v2" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

COUNT_AFTER=$(cast call "$BILLBOARD_PROXY" "updateCount()(uint256)" --rpc-url "$RPC_URL")
check "updateCount() incremented" "$((COUNT_BEFORE + 1))" "$COUNT_AFTER"

SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")
LAST_EDITOR=$(cast call "$BILLBOARD_PROXY" "lastEditor()(address)" --rpc-url "$RPC_URL")
check "lastEditor() recorded" "$SENDER" "$LAST_EDITOR"

MESSAGE_FINAL=$(cast call "$BILLBOARD_PROXY" "message()(string)" --rpc-url "$RPC_URL")
check "setMessage() via V2 works" '"upgraded to v2"' "$MESSAGE_FINAL"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Upgrade verified: all checks passed"
else
    echo "==> Upgrade verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
