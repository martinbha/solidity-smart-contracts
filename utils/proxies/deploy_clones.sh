#!/usr/bin/env bash
#
# deploy_clones.sh — deploy the ERC-1167 piggy bank factory and walk the
# clone lifecycle with two Anvil accounts:
#
#   deploy factory (it deploys the canonical implementation itself)
#   alice predicts her bank address, then creates it (same salt as bob —
#     creator-namespacing keeps them from colliding)
#   bob does the same; both deposit
#   before unlock: withdrawals revert, and alice cannot touch bob's bank
#   +1 day: both withdraw everything
#
# Verifies the predicted addresses match reality, each clone's bytecode is
# exactly the 45-byte EIP-1167 pattern with the implementation baked in,
# cross-bank access fails, and both banks drain to zero with the funds back
# in their owners' wallets.
#
# Usage: ./utils/proxies/deploy_clones.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev accounts: #0 deployer, #1 alice, #2 bob (public keys, local only).
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
ALICE_KEY="${ALICE_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
BOB_KEY="${BOB_KEY:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying piggy bank clone factory to chain $CHAIN_ID"
OUTPUT=$(forge script script/proxies/DeployPiggyBankFactory.s.sol:DeployPiggyBankFactory \
    --rpc-url "$RPC_URL" --broadcast)

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }
IMPL=$(parse_addr "PIGGY_IMPLEMENTATION")
FACTORY=$(parse_addr "PIGGY_FACTORY")

if [ -z "$IMPL" ] || [ -z "$FACTORY" ]; then
    echo "error: could not parse deploy addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/proxies/clones.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
PIGGY_IMPLEMENTATION=$IMPL
PIGGY_FACTORY=$FACTORY
EOF
echo "    implementation: $IMPL"
echo "    factory:        $FACTORY"

ALICE=$(cast wallet address --private-key "$ALICE_KEY")
BOB=$(cast wallet address --private-key "$BOB_KEY")
SALT=0x$(printf '%064x' 1) # same salt for both: creator-namespacing keeps them apart
DAY=86400
NOW=$(cast block latest -f timestamp --rpc-url "$RPC_URL")
UNLOCK=$((NOW + DAY))

FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}

# A real revert prints "revert" in cast's error output; anything else
# (RPC down, bad args) must fail the check rather than masquerade as one.
expect_revert() {
    local label="$1"; shift
    local out
    if out=$("$@" 2>&1); then check "$label" "revert" "success"
    elif echo "$out" | grep -qi "revert"; then check "$label" "revert" "revert"
    else check "$label" "revert" "unexpected error"; fi
}

echo ""
echo "==> Creating two banks with the SAME salt (unlock in 1 day)"
ALICE_BANK=$(cast call "$FACTORY" "predictBankAddress(address,bytes32)(address)" "$ALICE" "$SALT" --rpc-url "$RPC_URL")
BOB_BANK=$(cast call "$FACTORY" "predictBankAddress(address,bytes32)(address)" "$BOB" "$SALT" --rpc-url "$RPC_URL")

cast send "$FACTORY" "createBank(uint256,bytes32)" "$UNLOCK" "$SALT" \
    --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
cast send "$FACTORY" "createBank(uint256,bytes32)" "$UNLOCK" "$SALT" \
    --rpc-url "$RPC_URL" --private-key "$BOB_KEY" > /dev/null
echo "    alice's bank: $ALICE_BANK"
echo "    bob's bank:   $BOB_BANK"

echo ""
echo "==> Verifying the clones themselves"
# The whole contract is 45 bytes: the EIP-1167 prefix, the implementation
# address, and the suffix. Anything else at that address is not a clone.
IMPL_LOWER=$(echo "$IMPL" | tr 'A-F' 'a-f')
EXPECTED_CODE="0x363d3d373d3d3d363d73${IMPL_LOWER#0x}5af43d82803e903d91602b57fd5bf3"
check "alice's bank deployed at her predicted address" "1" \
    "$([ "$(cast code "$ALICE_BANK" --rpc-url "$RPC_URL")" != "0x" ] && echo 1 || echo 0)"
check "alice's bank is exactly the 45-byte EIP-1167 clone" "$EXPECTED_CODE" \
    "$(cast code "$ALICE_BANK" --rpc-url "$RPC_URL")"
check "same salt, different creators, different banks" "1" \
    "$([ "$ALICE_BANK" != "$BOB_BANK" ] && echo 1 || echo 0)"
check "alice owns her bank" "$ALICE" "$(cast call "$ALICE_BANK" "owner()(address)" --rpc-url "$RPC_URL")"
check "bob owns his bank" "$BOB" "$(cast call "$BOB_BANK" "owner()(address)" --rpc-url "$RPC_URL")"

echo ""
echo "==> Depositing (alice 1 ETH, bob 2 ETH) and testing the locks"
cast send "$ALICE_BANK" --value 1ether --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
cast send "$BOB_BANK" --value 2ether --rpc-url "$RPC_URL" --private-key "$BOB_KEY" > /dev/null

expect_revert "withdraw before unlock reverts" \
    cast send "$ALICE_BANK" "withdraw()" --rpc-url "$RPC_URL" --private-key "$ALICE_KEY"
expect_revert "alice cannot withdraw from bob's bank" \
    cast send "$BOB_BANK" "withdraw()" --rpc-url "$RPC_URL" --private-key "$ALICE_KEY"

echo ""
echo "==> +1 day: both owners withdraw"
cast rpc evm_increaseTime $((DAY + 60)) --rpc-url "$RPC_URL" > /dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" > /dev/null

ALICE_BEFORE=$(cast balance "$ALICE" --rpc-url "$RPC_URL")
BOB_BEFORE=$(cast balance "$BOB" --rpc-url "$RPC_URL")
cast send "$ALICE_BANK" "withdraw()" --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
cast send "$BOB_BANK" "withdraw()" --rpc-url "$RPC_URL" --private-key "$BOB_KEY" > /dev/null
ALICE_AFTER=$(cast balance "$ALICE" --rpc-url "$RPC_URL")
BOB_AFTER=$(cast balance "$BOB" --rpc-url "$RPC_URL")

echo ""
echo "==> Verifying balances"
check "alice's bank drained" "0" "$(cast balance "$ALICE_BANK" --rpc-url "$RPC_URL")"
check "bob's bank drained" "0" "$(cast balance "$BOB_BANK" --rpc-url "$RPC_URL")"
# bc: 18-decimal amounts exceed shell integer math; allow ~0.01 ETH for gas.
check "alice got her 1 ETH back (minus gas)" "1" \
    "$(echo "$ALICE_AFTER - $ALICE_BEFORE > 990000000000000000" | bc)"
check "bob got his 2 ETH back (minus gas)" "1" \
    "$(echo "$BOB_AFTER - $BOB_BEFORE > 1990000000000000000" | bc)"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Clone factory verified: all checks passed"
else
    echo "==> Clone verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
