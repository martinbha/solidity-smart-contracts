#!/usr/bin/env bash
#
# deploy_diamond.sh — deploy an EIP-2535 diamond, exercise it, then upgrade one
# facet on the live contract and verify on-chain:
#
#   1. calls route through the diamond to the counter facet (increment/count)
#   2. a live diamondCut REPLACES increment()/count() with a CounterFacetV2 and
#      ADDS a new incrementBy() selector — in one transaction
#   3. the counter VALUE survives the cut (state lives in diamond storage)
#   4. the new behavior is live: increment() now steps by 5, incrementBy() works
#   5. the loupe reports the new facet and drops the fully-replaced old one
#
# Records the deployment in deployments/upgradeable/diamond.<chain-id>.env.
#
# Config comes from .env at the repo root (see .env.example). With no .env it
# falls back to a local Anvil node and Anvil's well-known account #0.
#
# Usage: ./utils/upgradeable/diamond/deploy_diamond.sh

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

echo "==> Deploying diamond (cut + loupe + ownership + counter facets) to chain $CHAIN_ID"

OUTPUT=$(forge script script/upgradeable/diamond/DeployDiamond.s.sol:DeployDiamond \
    --rpc-url "$RPC_URL" --broadcast)
echo "$OUTPUT"

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }

DIAMOND=$(parse_addr "DIAMOND")
FACET_CUT=$(parse_addr "FACET_CUT")
FACET_LOUPE=$(parse_addr "FACET_LOUPE")
FACET_OWNERSHIP=$(parse_addr "FACET_OWNERSHIP")
FACET_COUNTER=$(parse_addr "FACET_COUNTER")

if [ -z "$DIAMOND" ] || [ -z "$FACET_COUNTER" ]; then
    echo "error: could not parse diamond addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/upgradeable/diamond.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
DIAMOND=$DIAMOND
FACET_CUT=$FACET_CUT
FACET_LOUPE=$FACET_LOUPE
FACET_OWNERSHIP=$FACET_OWNERSHIP
FACET_COUNTER=$FACET_COUNTER
EOF

echo ""
echo "==> Diamond deployed"
echo "    diamond:          $DIAMOND"
echo "    cut facet:        $FACET_CUT"
echo "    loupe facet:      $FACET_LOUPE"
echo "    ownership facet:  $FACET_OWNERSHIP"
echo "    counter facet V1: $FACET_COUNTER"
echo "    recorded in:      $DEPLOYMENT_FILE"

# ─── 1: exercise the counter through the diamond ────────────────────────────
echo ""
echo "==> Exercising the counter facet through the diamond"
for _ in 1 2 3; do
    cast send "$DIAMOND" "increment()" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
done
COUNT_BEFORE=$(cast call "$DIAMOND" "count()(uint256)" --rpc-url "$RPC_URL")
echo "    count after 3 increments: $COUNT_BEFORE"

# ─── 2: deploy V2 and cut it in on the live diamond ─────────────────────────
echo ""
echo "==> Deploying CounterFacetV2 and cutting it into the live diamond"
V2_OUTPUT=$(forge create src/upgradeable/diamond/facets/CounterFacetV2.sol:CounterFacetV2 \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast)
echo "$V2_OUTPUT"
FACET_COUNTER_V2=$(echo "$V2_OUTPUT" | grep -Eo 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}')

if [ -z "$FACET_COUNTER_V2" ]; then
    echo "error: could not parse CounterFacetV2 address" >&2
    exit 1
fi
echo "    counter facet V2: $FACET_COUNTER_V2"

INC_SEL=$(cast sig "increment()")
COUNT_SEL=$(cast sig "count()")
INCBY_SEL=$(cast sig "incrementBy(uint256)")
ZERO="0x0000000000000000000000000000000000000000"

# One cut, two instructions: Replace(1) the existing increment()/count()
# selectors onto V2, and Add(0) the brand-new incrementBy() selector.
cast send "$DIAMOND" "diamondCut((address,uint8,bytes4[])[],address,bytes)" \
    "[($FACET_COUNTER_V2,1,[$INC_SEL,$COUNT_SEL]),($FACET_COUNTER_V2,0,[$INCBY_SEL])]" \
    "$ZERO" "0x" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

# ─── verification ───────────────────────────────────────────────────────────
echo ""
echo "==> Verifying the live upgrade"
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

# 3: the counter value survived the cut
COUNT_AFTER_CUT=$(cast call "$DIAMOND" "count()(uint256)" --rpc-url "$RPC_URL")
check "count() preserved across cut" "$COUNT_BEFORE" "$COUNT_AFTER_CUT"

# 4a: increment() now steps by 5 (V2 behavior on the same selector)
cast send "$DIAMOND" "increment()" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
COUNT_AFTER_INC=$(cast call "$DIAMOND" "count()(uint256)" --rpc-url "$RPC_URL")
check "V2 increment() steps by 5" "$((COUNT_BEFORE + 5))" "$COUNT_AFTER_INC"

# 4b: the new incrementBy() selector is live
cast send "$DIAMOND" "incrementBy(uint256)" 10 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
COUNT_AFTER_INCBY=$(cast call "$DIAMOND" "count()(uint256)" --rpc-url "$RPC_URL")
check "new incrementBy() selector live" "$((COUNT_BEFORE + 15))" "$COUNT_AFTER_INCBY"

# 5: the loupe now routes those selectors to V2, not the old counter facet
LOUPE_INC=$(cast call "$DIAMOND" "facetAddress(bytes4)(address)" "$INC_SEL" --rpc-url "$RPC_URL")
check "loupe routes increment() to V2" \
    "$(cast to-check-sum-address "$FACET_COUNTER_V2")" "$(cast to-check-sum-address "$LOUPE_INC")"

# the old V1 counter facet should no longer appear among the facet addresses
if cast call "$DIAMOND" "facetAddresses()(address[])" --rpc-url "$RPC_URL" \
    | grep -qi "${FACET_COUNTER#0x}"; then
    echo "    FAIL  old counter facet V1 still listed by loupe"
    FAILURES=$((FAILURES + 1))
else
    echo "    PASS  old counter facet V1 dropped from loupe"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Diamond upgrade verified: all checks passed"
else
    echo "==> Diamond upgrade verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
