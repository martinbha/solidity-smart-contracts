#!/usr/bin/env bash
#
# deploy_1271.sh — deploy the EIP-1271 order book + a 2-of-3 signer multisig
# and settle orders from both an EOA maker and a contract maker:
#
#   fill an order signed by an EOA maker (one ecrecover signature)
#   fill an order signed by the multisig (two owner signatures concatenated),
#     after the multisig approves the book via a threshold-signed execute
#   show a single-owner multisig signature is rejected (below threshold)
#
# The order book calls OZ SignatureChecker.isValidSignatureNow, which branches
# on the maker's code size: EOA -> ecrecover, contract -> EIP-1271. Same
# fillOrder path settles both.
#
# Usage: ./utils/signatures/erc1271/deploy_1271.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev account #0 (deployer + taker). Public keys below are local only.
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
# Multisig owners: anvil dev accounts #1, #2, #3.
OWNER1_KEY="${OWNER1_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
OWNER2_KEY="${OWNER2_KEY:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"
# EOA maker: anvil dev account #4.
EOA_MAKER_KEY="${EOA_MAKER_KEY:-0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a}"

TAKER=$(cast wallet address "$PRIVATE_KEY")
EOA_MAKER=$(cast wallet address "$EOA_MAKER_KEY")

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying order book + 2-of-3 signer multisig to chain $CHAIN_ID"
OUTPUT=$(forge script script/signatures/erc1271/DeployOrderBook.s.sol:DeployOrderBook \
    --rpc-url "$RPC_URL" --broadcast)

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }
BOOK=$(parse_addr "ORDER_BOOK")
TOKEN=$(parse_addr "ORDER_TOKEN")
MULTISIG=$(parse_addr "SIGNER_MULTISIG")

if [ -z "$BOOK" ] || [ -z "$TOKEN" ] || [ -z "$MULTISIG" ]; then
    echo "error: could not parse deploy addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/signatures/erc1271/orderbook.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
ORDER_BOOK=$BOOK
ORDER_TOKEN=$TOKEN
SIGNER_MULTISIG=$MULTISIG
EOF
echo "    book:     $BOOK"
echo "    token:    $TOKEN"
echo "    multisig: $MULTISIG"

AMOUNT=100000000000000000000 # 100 ORD
PRICE=1000000000000000000 # 1 ETH

# Concatenate two 65-byte signatures over $2 in ascending signer-address order,
# as SignerMultisig requires. $1 must be a space-separated pair of keys.
sorted_multisig_sig() {
    local keys="$1" digest="$2" ka kb aa ab sa sb
    read -r ka kb <<< "$keys"
    aa=$(cast wallet address "$ka"); ab=$(cast wallet address "$kb")
    sa=$(cast wallet sign --no-hash --private-key "$ka" "$digest")
    sb=$(cast wallet sign --no-hash --private-key "$kb" "$digest")
    # Lowercase compare so the ordering matches on-chain address comparison.
    if [ "$(echo "$aa" | tr 'A-F' 'a-f')" \< "$(echo "$ab" | tr 'A-F' 'a-f')" ]; then
        echo "0x${sa#0x}${sb#0x}"
    else
        echo "0x${sb#0x}${sa#0x}"
    fi
}

order_tuple() { echo "($1,$TOKEN,$AMOUNT,$PRICE,$2)"; } # (maker, nonce)

FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}

# --- EOA-signed order --------------------------------------------------------

echo ""
echo "==> Order 1: EOA maker $EOA_MAKER"
cast send "$TOKEN" "mint(address,uint256)" "$EOA_MAKER" "$AMOUNT" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
cast send "$TOKEN" "approve(address,uint256)" "$BOOK" "$AMOUNT" \
    --rpc-url "$RPC_URL" --private-key "$EOA_MAKER_KEY" > /dev/null

EOA_ORDER=$(order_tuple "$EOA_MAKER" 0)
EOA_DIGEST=$(cast call "$BOOK" \
    "hashOrder((address,address,uint256,uint256,uint256))(bytes32)" "$EOA_ORDER" \
    --rpc-url "$RPC_URL")
EOA_SIG=$(cast wallet sign --no-hash --private-key "$EOA_MAKER_KEY" "$EOA_DIGEST")

cast send "$BOOK" "fillOrder((address,address,uint256,uint256,uint256),bytes)" \
    "$EOA_ORDER" "$EOA_SIG" --value "$PRICE" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
check "EOA order filled (taker got the tokens)" "$AMOUNT" \
    "$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$TAKER" --rpc-url "$RPC_URL" | awk '{print $1}')"

# --- Multisig-signed order ---------------------------------------------------

echo ""
echo "==> Order 2: contract maker (2-of-3 multisig) $MULTISIG"
# The multisig must approve the book itself — a threshold-signed execute
# calling token.approve, since a pure signer has no other way to grant it.
APPROVE_CALL=$(cast calldata "approve(address,uint256)" "$BOOK" "$AMOUNT")
MS_NONCE=$(cast call "$MULTISIG" "nonce()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
EXEC_DIGEST=$(cast call "$MULTISIG" \
    "hashExecute(address,uint256,bytes,uint256)(bytes32)" \
    "$TOKEN" 0 "$APPROVE_CALL" "$MS_NONCE" --rpc-url "$RPC_URL")
EXEC_SIG=$(sorted_multisig_sig "$OWNER1_KEY $OWNER2_KEY" "$EXEC_DIGEST")
echo "    multisig approves the book via threshold-signed execute"
cast send "$MULTISIG" "execute(address,uint256,bytes,bytes)" \
    "$TOKEN" 0 "$APPROVE_CALL" "$EXEC_SIG" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

MS_ORDER=$(order_tuple "$MULTISIG" 0)
MS_DIGEST=$(cast call "$BOOK" \
    "hashOrder((address,address,uint256,uint256,uint256))(bytes32)" "$MS_ORDER" \
    --rpc-url "$RPC_URL")
MS_SIG=$(sorted_multisig_sig "$OWNER1_KEY $OWNER2_KEY" "$MS_DIGEST")

MS_ETH_BEFORE=$(cast balance "$MULTISIG" --rpc-url "$RPC_URL")
cast send "$BOOK" "fillOrder((address,address,uint256,uint256,uint256),bytes)" \
    "$MS_ORDER" "$MS_SIG" --value "$PRICE" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
MS_ETH_AFTER=$(cast balance "$MULTISIG" --rpc-url "$RPC_URL")

check "multisig order filled (taker holds 200 ORD total)" "200000000000000000000" \
    "$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$TAKER" --rpc-url "$RPC_URL" | awk '{print $1}')"
check "multisig maker received the ETH price" "$PRICE" "$(echo "$MS_ETH_AFTER - $MS_ETH_BEFORE" | bc)"

# --- Below-threshold rejection ----------------------------------------------

echo ""
echo "==> Order 3: single-owner multisig signature must be rejected"
REJECT_ORDER=$(order_tuple "$MULTISIG" 1)
REJECT_DIGEST=$(cast call "$BOOK" \
    "hashOrder((address,address,uint256,uint256,uint256))(bytes32)" "$REJECT_ORDER" \
    --rpc-url "$RPC_URL")
# Only ONE owner signs — below the 2-of-3 threshold.
ONE_SIG=$(cast wallet sign --no-hash --private-key "$OWNER1_KEY" "$REJECT_DIGEST")

if cast send "$BOOK" "fillOrder((address,address,uint256,uint256,uint256),bytes)" \
    "$REJECT_ORDER" "$ONE_SIG" --value "$PRICE" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null 2>&1; then
    echo "    FAIL  single-owner signature was accepted (should have reverted)"
    FAILURES=$((FAILURES + 1))
else
    check "single-owner signature rejected below threshold" "rejected" "rejected"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> EIP-1271 verified: all checks passed"
else
    echo "==> EIP-1271 verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
