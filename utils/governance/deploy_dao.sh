#!/usr/bin/env bash
#
# deploy_dao.sh — deploy the DAO stack (ERC20Votes token, TimelockController,
# Governor, timelock-owned treasury) and ship one decision end to end:
#
#   deploy + wire roles (governor = proposer, anyone = executor, admin
#     renounced); the deployer holds 1000 GOV and delegates to itself
#   propose a 5 ETH treasury grant, mine past the voting delay, vote For,
#     mine past the voting period, queue into the timelock, warp past the
#     timelock delay, execute
#
# Verifies every lifecycle state on the way (Pending → Active → Succeeded →
# Queued → Executed) and that the grant landed exactly as encoded.
#
# Usage: ./utils/governance/deploy_dao.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev account #0 (public key, local only).
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying DAO stack to chain $CHAIN_ID"
# The optimized profile: the Governor exceeds the 24KB size limit unoptimized.
OUTPUT=$(FOUNDRY_PROFILE=optimized forge script script/governance/DeployDao.s.sol:DeployDao \
    --rpc-url "$RPC_URL" --broadcast)

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }
TOKEN=$(parse_addr "GOV_TOKEN")
TIMELOCK=$(parse_addr "TIMELOCK")
GOVERNOR=$(parse_addr "DAO_GOVERNOR")
TREASURY=$(parse_addr "TREASURY")

if [ -z "$TOKEN" ] || [ -z "$TIMELOCK" ] || [ -z "$GOVERNOR" ] || [ -z "$TREASURY" ]; then
    echo "error: could not parse deploy addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/governance/dao.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
GOV_TOKEN=$TOKEN
TIMELOCK=$TIMELOCK
DAO_GOVERNOR=$GOVERNOR
TREASURY=$TREASURY
EOF
echo "    token:    $TOKEN"
echo "    timelock: $TIMELOCK"
echo "    governor: $GOVERNOR"
echo "    treasury: $TREASURY"

mine() { cast rpc anvil_mine "$1" --rpc-url "$RPC_URL" > /dev/null; }
prop_state() { cast call "$GOVERNOR" "state(uint256)(uint8)" "$PROPOSAL_ID" --rpc-url "$RPC_URL"; }

FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}

GRANT=5000000000000000000 # 5 ETH
# Anvil dev account #3: the grant recipient.
RECIPIENT="0x90F79bf6EB2c4f870365E785982E1f101E93b906"
DESCRIPTION="Grant: pay the recipient 5 ETH from the treasury"
DESC_HASH=$(cast keccak "$DESCRIPTION")
CALLDATA=$(cast calldata "release(address,uint256)" "$RECIPIENT" "$GRANT")

echo ""
echo "==> Delegating: balances are not votes until delegated (even to yourself)"
cast send "$TOKEN" "delegate(address)" "$(cast wallet address "$PRIVATE_KEY")" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

echo ""
echo "==> Proposing the grant"
cast send "$GOVERNOR" "propose(address[],uint256[],bytes[],string)" \
    "[$TREASURY]" "[0]" "[$CALLDATA]" "$DESCRIPTION" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
PROPOSAL_ID=$(cast call "$GOVERNOR" "hashProposal(address[],uint256[],bytes[],bytes32)(uint256)" \
    "[$TREASURY]" "[0]" "[$CALLDATA]" "$DESC_HASH" --rpc-url "$RPC_URL" | awk '{print $1}')
check "proposal is Pending before the voting delay" "0" "$(prop_state)"

echo ""
echo "==> Mining past the voting delay, voting For"
mine 2
check "proposal is Active in the voting window" "1" "$(prop_state)"
cast send "$GOVERNOR" "castVote(uint256,uint8)" "$PROPOSAL_ID" 1 \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

echo ""
echo "==> Mining past the voting period"
mine 11
check "proposal Succeeded after the period" "4" "$(prop_state)"

echo ""
echo "==> Queueing into the timelock (the exit window starts now)"
cast send "$GOVERNOR" "queue(address[],uint256[],bytes[],bytes32)" \
    "[$TREASURY]" "[0]" "[$CALLDATA]" "$DESC_HASH" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
check "proposal Queued in the timelock" "5" "$(prop_state)"

echo ""
echo "==> Warping past the timelock delay, executing"
cast rpc evm_increaseTime 61 --rpc-url "$RPC_URL" > /dev/null
mine 1
RECIPIENT_BEFORE=$(cast balance "$RECIPIENT" --rpc-url "$RPC_URL")
TREASURY_BEFORE=$(cast balance "$TREASURY" --rpc-url "$RPC_URL")
cast send "$GOVERNOR" "execute(address[],uint256[],bytes[],bytes32)" \
    "[$TREASURY]" "[0]" "[$CALLDATA]" "$DESC_HASH" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
RECIPIENT_AFTER=$(cast balance "$RECIPIENT" --rpc-url "$RPC_URL")
TREASURY_AFTER=$(cast balance "$TREASURY" --rpc-url "$RPC_URL")

echo ""
echo "==> Verifying"
check "proposal Executed" "7" "$(prop_state)"
# bc: wei amounts exceed shell integer math.
check "recipient received exactly the grant" "$GRANT" "$(echo "$RECIPIENT_AFTER - $RECIPIENT_BEFORE" | bc)"
check "treasury paid exactly the grant" "$GRANT" "$(echo "$TREASURY_BEFORE - $TREASURY_AFTER" | bc)"
echo "    treasury: $(cast from-wei "$TREASURY_BEFORE") -> $(cast from-wei "$TREASURY_AFTER") ETH"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> DAO verified: all checks passed"
else
    echo "==> DAO verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
