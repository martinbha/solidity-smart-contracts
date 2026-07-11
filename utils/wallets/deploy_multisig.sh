#!/usr/bin/env bash
#
# deploy_multisig.sh — deploy a 2-of-3 MultisigWallet and demonstrate a real
# m-of-n send with off-chain EIP-712 signatures:
#
#   deploy 2-of-3 owned by Anvil accounts #0, #1, #2
#   fund the wallet with 5 ETH
#   build the EIP-712 digest for "send 1 ETH to the recipient" (via txHash)
#   two owners sign the digest off-chain (cast wallet sign --no-hash)
#   a single execute() call submits the bundle
#   verify the recipient received the ETH and the nonce advanced
#
# Usage: ./utils/wallets/deploy_multisig.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev accounts #0..#2 (public keys, local only): #0 deploys and relays,
# all three are wallet owners.
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
OWNER1_KEY="${OWNER1_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
OWNER2_KEY="${OWNER2_KEY:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"

export OWNER_0 OWNER_1 OWNER_2
OWNER_0=$(cast wallet address --private-key "$PRIVATE_KEY")
OWNER_1=$(cast wallet address --private-key "$OWNER1_KEY")
OWNER_2=$(cast wallet address --private-key "$OWNER2_KEY")

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying 2-of-3 multisig to chain $CHAIN_ID"
echo "    owners: $OWNER_0 $OWNER_1 $OWNER_2"
OUTPUT=$(forge script script/wallets/DeployMultisig.s.sol:DeployMultisig \
    --rpc-url "$RPC_URL" --broadcast)

WALLET=$(echo "$OUTPUT" | grep -Eo "MULTISIG_WALLET: 0x[0-9a-fA-F]{40}" | awk '{print $2}')
[ -n "$WALLET" ] || { echo "error: could not parse wallet address from deploy output" >&2; exit 1; }
echo "    wallet: $WALLET"

echo "==> Funding the wallet with 5 ETH"
cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
    "$WALLET" --value 5ether >/dev/null

RECIPIENT=0x00000000000000000000000000000000DeaDBeef
VALUE=1000000000000000000 # 1 ETH
NONCE=$(cast call --rpc-url "$RPC_URL" "$WALLET" "nonce()(uint256)")
TXN="($RECIPIENT,$VALUE,0x,$NONCE)"
BALANCE_BEFORE=$(cast balance --rpc-url "$RPC_URL" "$RECIPIENT")

echo "==> Building EIP-712 digest for: send 1 ETH to $RECIPIENT (nonce $NONCE)"
DIGEST=$(cast call --rpc-url "$RPC_URL" "$WALLET" \
    "txHash((address,uint256,bytes,uint256))(bytes32)" "$TXN")
echo "    digest: $DIGEST"

echo "==> Owners #1 and #2 sign the digest off-chain"
SIG_1=$(cast wallet sign --no-hash --private-key "$OWNER1_KEY" "$DIGEST")
SIG_2=$(cast wallet sign --no-hash --private-key "$OWNER2_KEY" "$DIGEST")

# execute() requires signatures sorted by ascending signer address.
LOWER_1=$(echo "$OWNER_1" | tr '[:upper:]' '[:lower:]')
LOWER_2=$(echo "$OWNER_2" | tr '[:upper:]' '[:lower:]')
if [[ "$LOWER_1" < "$LOWER_2" ]]; then
    SIGS="[$SIG_1,$SIG_2]"
else
    SIGS="[$SIG_2,$SIG_1]"
fi

echo "==> Submitting the signed bundle via execute() (relayer: owner #0)"
cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
    "$WALLET" "execute((address,uint256,bytes,uint256),bytes[])" \
    "$TXN" "$SIGS" >/dev/null

BALANCE_AFTER=$(cast balance --rpc-url "$RPC_URL" "$RECIPIENT")
NEW_NONCE=$(cast call --rpc-url "$RPC_URL" "$WALLET" "nonce()(uint256)")

# Wei amounts overflow bash's 64-bit arithmetic past ~9.2 ETH, so use bc.
RECEIVED=$(echo "$BALANCE_AFTER - $BALANCE_BEFORE" | bc)
if [ "$RECEIVED" != "$VALUE" ]; then
    echo "error: recipient balance moved by $RECEIVED, expected $VALUE" >&2
    exit 1
fi
if [ "$NEW_NONCE" -ne $((NONCE + 1)) ]; then
    echo "error: nonce is $NEW_NONCE, expected $((NONCE + 1))" >&2
    exit 1
fi

echo "==> OK: recipient received 1 ETH, wallet nonce advanced to $NEW_NONCE"
