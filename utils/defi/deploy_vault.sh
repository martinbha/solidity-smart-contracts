#!/usr/bin/env bash
#
# deploy_vault.sh — deploy the ERC-4626 yield vault and walk the full
# deposit → harvest → withdraw lifecycle with two depositors:
#
#   alice (Anvil #1) deposits 1000 VAST      → in for both harvests
#   harvest #1 (10% on 1000 = 100 yield)     → only alice's share price rises
#   bob   (Anvil #2) deposits 1000 VAST      → in for the second harvest only
#   harvest #2 (10% on ~2100 = ~210 yield)   → split pro-rata
#   both redeem everything                    → principal + proportional yield
#
# Verifies both got at least principal back and alice (earlier, longer
# exposure) earned strictly more than bob.
#
# Usage: ./utils/defi/deploy_vault.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev accounts: #0 deployer/owner, #1 alice, #2 bob (public keys, local only).
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
ALICE_KEY="${ALICE_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
BOB_KEY="${BOB_KEY:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying yield vault to chain $CHAIN_ID"
OUTPUT=$(forge script script/defi/DeployYieldVault.s.sol:DeployYieldVault \
    --rpc-url "$RPC_URL" --broadcast)

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }
ASSET=$(parse_addr "VAULT_ASSET")
SOURCE=$(parse_addr "YIELD_SOURCE")
VAULT=$(parse_addr "YIELD_VAULT")

if [ -z "$ASSET" ] || [ -z "$SOURCE" ] || [ -z "$VAULT" ]; then
    echo "error: could not parse deploy addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/defi/vault.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
VAULT_ASSET=$ASSET
YIELD_SOURCE=$SOURCE
YIELD_VAULT=$VAULT
EOF
echo "    asset:  $ASSET"
echo "    source: $SOURCE"
echo "    vault:  $VAULT"

ALICE=$(cast wallet address --private-key "$ALICE_KEY")
BOB=$(cast wallet address --private-key "$BOB_KEY")
DEPOSIT=1000000000000000000000 # 1000 VAST

fund_and_approve() {
    local who="$1" key="$2"
    cast send "$ASSET" "mint(address,uint256)" "$who" "$DEPOSIT" \
        --rpc-url "$RPC_URL" --private-key "$key" > /dev/null
    cast send "$ASSET" "approve(address,uint256)" "$VAULT" "$DEPOSIT" \
        --rpc-url "$RPC_URL" --private-key "$key" > /dev/null
}

echo ""
echo "==> Running deposit / harvest / withdraw lifecycle"
fund_and_approve "$ALICE" "$ALICE_KEY"
cast send "$VAULT" "deposit(uint256,address)" "$DEPOSIT" "$ALICE" \
    --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
echo "    alice deposited 1000 VAST"

cast send "$VAULT" "harvest()" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
echo "    harvest #1 (alice alone in the vault)"

fund_and_approve "$BOB" "$BOB_KEY"
cast send "$VAULT" "deposit(uint256,address)" "$DEPOSIT" "$BOB" \
    --rpc-url "$RPC_URL" --private-key "$BOB_KEY" > /dev/null
echo "    bob deposited 1000 VAST"

cast send "$VAULT" "harvest()" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
echo "    harvest #2 (both in the vault)"

redeem_all() {
    local who="$1" key="$2"
    local shares
    shares=$(cast call "$VAULT" "balanceOf(address)(uint256)" "$who" --rpc-url "$RPC_URL" | awk '{print $1}')
    cast send "$VAULT" "redeem(uint256,address,address)" "$shares" "$who" "$who" \
        --rpc-url "$RPC_URL" --private-key "$key" > /dev/null
}
redeem_all "$ALICE" "$ALICE_KEY"
redeem_all "$BOB" "$BOB_KEY"
echo "    both redeemed all shares"

echo ""
echo "==> Verifying"
FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}

ALICE_OUT=$(cast call "$ASSET" "balanceOf(address)(uint256)" "$ALICE" --rpc-url "$RPC_URL" | awk '{print $1}')
BOB_OUT=$(cast call "$ASSET" "balanceOf(address)(uint256)" "$BOB" --rpc-url "$RPC_URL" | awk '{print $1}')
echo "    alice ended with $(cast from-wei "$ALICE_OUT") VAST"
echo "    bob   ended with $(cast from-wei "$BOB_OUT") VAST"

# bc: 18-decimal amounts exceed shell integer math.
check "alice got principal + yield back" "1" "$(echo "$ALICE_OUT > $DEPOSIT" | bc)"
check "bob got at least principal back" "1" "$(echo "$BOB_OUT >= $DEPOSIT - 1" | bc)"
check "bob earned yield from harvest #2" "1" "$(echo "$BOB_OUT > $DEPOSIT" | bc)"
check "early alice earned more than late bob" "1" "$(echo "$ALICE_OUT > $BOB_OUT" | bc)"
check "vault paid out all shares" "0" \
    "$(cast call "$VAULT" "totalSupply()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Vault verified: all checks passed"
else
    echo "==> Vault verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
