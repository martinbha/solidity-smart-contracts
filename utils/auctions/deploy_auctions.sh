#!/usr/bin/env bash
#
# deploy_auctions.sh — deploy the auction house and run a full scripted English
# auction to verify the escrow → bid → outbid → settle → withdraw flow:
#
#   seller lists an NFT (escrowed on create)
#   alice (Anvil #1) bids 1 ETH
#   bob   (Anvil #2) outbids with 2 ETH  → alice's 1 ETH becomes withdrawable
#   time warped past the end, settled     → bob gets the NFT, seller gets 2 ETH
#   alice withdraws her refunded 1 ETH
#
# Also verifies the Dutch price decays below its start after time passes.
#
# Usage: ./utils/auctions/deploy_auctions.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev accounts: #0 seller/deployer, #1 alice, #2 bob (public keys, local only).
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
ALICE_KEY="${ALICE_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
BOB_KEY="${BOB_KEY:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying auction house to chain $CHAIN_ID"
OUTPUT=$(forge script script/auctions/DeployAuctionHouse.s.sol:DeployAuctionHouse \
    --rpc-url "$RPC_URL" --broadcast)

parse() { echo "$OUTPUT" | grep -Eo "$1: [0-9a-fApx]+" | awk '{print $2}'; }
HOUSE=$(echo "$OUTPUT" | grep -Eo 'AUCTION_HOUSE: 0x[0-9a-fA-F]{40}' | awk '{print $2}')
NFT=$(echo "$OUTPUT" | grep -Eo 'AUCTION_NFT: 0x[0-9a-fA-F]{40}' | awk '{print $2}')
ENGLISH_ID=$(parse "ENGLISH_AUCTION_ID")
ENGLISH_TOKEN=$(parse "ENGLISH_TOKEN_ID")
DUTCH_ID=$(parse "DUTCH_AUCTION_ID")

if [ -z "$HOUSE" ] || [ -z "$NFT" ]; then
    echo "error: could not parse deploy addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/auctions/auctions.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
AUCTION_HOUSE=$HOUSE
AUCTION_NFT=$NFT
EOF
echo "    house: $HOUSE"
echo "    nft:   $NFT"

ALICE=$(cast wallet address --private-key "$ALICE_KEY")
BOB=$(cast wallet address --private-key "$BOB_KEY")
SELLER=$(cast wallet address --private-key "$PRIVATE_KEY")

echo ""
echo "==> Running English auction $ENGLISH_ID (token $ENGLISH_TOKEN)"
cast send "$HOUSE" "bid(uint256)" "$ENGLISH_ID" --value 1ether \
    --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
echo "    alice bid 1 ETH"
cast send "$HOUSE" "bid(uint256)" "$ENGLISH_ID" --value 2ether \
    --rpc-url "$RPC_URL" --private-key "$BOB_KEY" > /dev/null
echo "    bob outbid with 2 ETH"

# Warp past the (possibly extended) end and settle.
cast rpc evm_increaseTime 90000 --rpc-url "$RPC_URL" > /dev/null # 25h > 1 day + extension
cast rpc evm_mine --rpc-url "$RPC_URL" > /dev/null
cast send "$HOUSE" "settleEnglish(uint256)" "$ENGLISH_ID" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
echo "    settled"

echo ""
echo "==> Verifying"
FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label: $actual"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}

check "winner owns the NFT" "$(echo "$BOB" | tr 'A-F' 'a-f')" \
    "$(cast call "$NFT" "ownerOf(uint256)(address)" "$ENGLISH_TOKEN" --rpc-url "$RPC_URL" | tr 'A-F' 'a-f')"
check "seller credited 2 ETH" "2000000000000000000" \
    "$(cast call "$HOUSE" "balances(address)(uint256)" "$SELLER" --rpc-url "$RPC_URL" | awk '{print $1}')"
check "outbid alice credited 1 ETH" "1000000000000000000" \
    "$(cast call "$HOUSE" "balances(address)(uint256)" "$ALICE" --rpc-url "$RPC_URL" | awk '{print $1}')"

# Alice withdraws her refund (bc: 18-decimal amounts exceed shell math).
BEFORE=$(cast balance "$ALICE" --rpc-url "$RPC_URL")
cast send "$HOUSE" "withdraw()" --rpc-url "$RPC_URL" --private-key "$ALICE_KEY" > /dev/null
AFTER=$(cast balance "$ALICE" --rpc-url "$RPC_URL")
check "alice withdrew ~1 ETH" "1" "$(echo "$AFTER - $BEFORE > 900000000000000000" | bc)"

# Dutch price has decayed below the 10 ETH start after the time warp.
DUTCH_PRICE=$(cast call "$HOUSE" "currentPrice(uint256)(uint256)" "$DUTCH_ID" --rpc-url "$RPC_URL" | awk '{print $1}')
check "dutch price decayed to floor" "1" "$(echo "$DUTCH_PRICE == 2000000000000000000" | bc)"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Auctions verified: all checks passed"
else
    echo "==> Auction verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
