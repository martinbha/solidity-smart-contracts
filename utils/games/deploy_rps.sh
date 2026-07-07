#!/usr/bin/env bash
#
# deploy_rps.sh — deploy RockPaperScissors and play a full scripted match to
# verify the commit-reveal flow end to end:
#
#   player 1 (Anvil #0) commits Rock,     stakes 1 ETH
#   player 2 (Anvil #1) commits Scissors, stakes 1 ETH
#   both reveal -> settle -> Rock wins -> player 1 withdraws the 2 ETH pot
#
# Verifies on-chain: pot credited to the winner only, withdrawal moves real
# ETH, contract balance drains to zero, and a reveal with the wrong salt is
# rejected.
#
# Usage: ./utils/games/deploy_rps.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev accounts #0 and #1 (publicly known keys, local use only).
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
P2_KEY="${P2_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying RockPaperScissors to chain $CHAIN_ID"
OUTPUT=$(forge script script/games/DeployRPS.s.sol:DeployRPS --rpc-url "$RPC_URL" --broadcast)
RPS=$(echo "$OUTPUT" | grep -Eo 'RPS_ADDRESS: 0x[0-9a-fA-F]{40}' | awk '{print $2}')
if [ -z "$RPS" ]; then
    echo "error: could not parse contract address from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/games/rps.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
echo "RPS_ADDRESS=$RPS" > "$DEPLOYMENT_FILE"
echo "    contract:    $RPS"
echo "    recorded in: $DEPLOYMENT_FILE"

P1=$(cast wallet address --private-key "$PRIVATE_KEY")
P2=$(cast wallet address --private-key "$P2_KEY")
STAKE="1000000000000000000" # 1 ETH
ROCK=1
SCISSORS=3

# Fresh random salts per run — the whole point of commit-reveal is that a
# 3-value move space is only safe behind an unguessable salt.
SALT1=$(cast keccak "$(date +%s%N)-p1-$RANDOM")
SALT2=$(cast keccak "$(date +%s%N)-p2-$RANDOM")

COMMIT1=$(cast call "$RPS" "hashMove(uint8,bytes32,address)(bytes32)" $ROCK "$SALT1" "$P1" --rpc-url "$RPC_URL")
COMMIT2=$(cast call "$RPS" "hashMove(uint8,bytes32,address)(bytes32)" $SCISSORS "$SALT2" "$P2" --rpc-url "$RPC_URL")

echo ""
echo "==> Playing a match: $P1 (Rock) vs $P2 (Scissors)"
GAME_ID=$(cast call "$RPS" "gamesCount()(uint256)" --rpc-url "$RPC_URL")

cast send "$RPS" "createGame(bytes32)" "$COMMIT1" --value "$STAKE" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
echo "    game $GAME_ID created (P1 committed + staked 1 ETH)"

cast send "$RPS" "joinGame(uint256,bytes32)" "$GAME_ID" "$COMMIT2" --value "$STAKE" \
    --rpc-url "$RPC_URL" --private-key "$P2_KEY" > /dev/null
echo "    P2 joined (committed + staked 1 ETH) — reveal window open"

cast send "$RPS" "reveal(uint256,uint8,bytes32)" "$GAME_ID" $ROCK "$SALT1" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
cast send "$RPS" "reveal(uint256,uint8,bytes32)" "$GAME_ID" $SCISSORS "$SALT2" \
    --rpc-url "$RPC_URL" --private-key "$P2_KEY" > /dev/null
echo "    both revealed"

cast send "$RPS" "settle(uint256)" "$GAME_ID" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
echo "    settled"

echo ""
echo "==> Verifying"
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

# Rock beats scissors: the full pot sits in P1's pull-payment balance.
POT=$(echo "$STAKE * 2" | bc)
check "winner credited the pot" "$POT" "$(cast call "$RPS" "balances(address)(uint256)" "$P1" --rpc-url "$RPC_URL" | awk '{print $1}')"
check "loser credited nothing" "0" "$(cast call "$RPS" "balances(address)(uint256)" "$P2" --rpc-url "$RPC_URL" | awk '{print $1}')"

# Withdrawal moves real ETH (bc: amounts exceed 64-bit shell math).
BEFORE=$(cast balance "$P1" --rpc-url "$RPC_URL")
cast send "$RPS" "withdraw()" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
AFTER=$(cast balance "$P1" --rpc-url "$RPC_URL")
GAINED=$(echo "$AFTER - $BEFORE > 1900000000000000000" | bc) # pot minus gas
check "withdraw moved ~2 ETH to winner" "1" "$GAINED"
check "contract fully drained" "0" "$(cast balance "$RPS" --rpc-url "$RPC_URL")"

# A wrong-salt reveal must be rejected (fresh game to prove it).
BAD_GAME=$(cast call "$RPS" "gamesCount()(uint256)" --rpc-url "$RPC_URL")
cast send "$RPS" "createGame(bytes32)" "$COMMIT1" --value 0 \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
cast send "$RPS" "joinGame(uint256,bytes32)" "$BAD_GAME" "$COMMIT2" --value 0 \
    --rpc-url "$RPC_URL" --private-key "$P2_KEY" > /dev/null
if cast send "$RPS" "reveal(uint256,uint8,bytes32)" "$BAD_GAME" $ROCK "$SALT2" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null 2>&1; then
    check "wrong-salt reveal rejected" "revert" "succeeded"
else
    check "wrong-salt reveal rejected" "revert" "revert"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Match verified: all checks passed"
else
    echo "==> Match verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
