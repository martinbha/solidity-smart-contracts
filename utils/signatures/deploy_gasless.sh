#!/usr/bin/env bash
#
# deploy_gasless.sh — deploy the gasless stack (EIP-2612 permit token,
# ERC-2771 minimal forwarder, vault trusting the forwarder) and run both
# signature tricks end to end:
#
#   1. permit kills approve-then-spend: a token holder signs an EIP-712
#      permit off-chain, then a SINGLE depositWithPermit transaction sets
#      the allowance and pulls the tokens — no approve tx ever happens
#   2. fully gasless: a freshly generated wallet with ZERO ETH signs a
#      permit plus a ForwardRequest; a funded relayer submits both through
#      the forwarder and pays all gas while the vault credits the signer
#
# Verifies the fresh user's ETH balance never changed (0 wei before and
# after) while their intent executed on-chain.
#
# Usage: ./utils/signatures/deploy_gasless.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev accounts #0 (deployer) and #1 (relayer) — public keys, local only.
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
RELAYER_KEY="${RELAYER_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
# Anvil dev account #2: the demo-1 depositor (funded, sends its own single tx).
HOLDER_KEY="${HOLDER_KEY:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying gasless stack to chain $CHAIN_ID"
OUTPUT=$(forge script script/signatures/DeployGasless.s.sol:DeployGasless \
    --rpc-url "$RPC_URL" --broadcast)

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }
TOKEN=$(parse_addr "PERMIT_TOKEN")
FORWARDER=$(parse_addr "FORWARDER")
VAULT=$(parse_addr "GASLESS_VAULT")

if [ -z "$TOKEN" ] || [ -z "$FORWARDER" ] || [ -z "$VAULT" ]; then
    echo "error: could not parse deploy addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/signatures/gasless.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
PERMIT_TOKEN=$TOKEN
FORWARDER=$FORWARDER
GASLESS_VAULT=$VAULT
EOF
echo "    token:     $TOKEN"
echo "    forwarder: $FORWARDER"
echo "    vault:     $VAULT"

DEADLINE=$(($(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600))

# Signs an EIP-2612 permit (owner -> $VAULT for $2 tokens) with key $1 and
# prints the 65-byte signature. Reads the owner's current token nonce.
sign_permit() {
    local key="$1" value="$2"
    local owner nonce
    owner=$(cast wallet address "$key")
    nonce=$(cast call "$TOKEN" "nonces(address)(uint256)" "$owner" --rpc-url "$RPC_URL")
    cast wallet sign --private-key "$key" --data "$(cat <<JSON
{
  "types": {
    "EIP712Domain": [
      {"name": "name", "type": "string"},
      {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"},
      {"name": "verifyingContract", "type": "address"}
    ],
    "Permit": [
      {"name": "owner", "type": "address"},
      {"name": "spender", "type": "address"},
      {"name": "value", "type": "uint256"},
      {"name": "nonce", "type": "uint256"},
      {"name": "deadline", "type": "uint256"}
    ]
  },
  "primaryType": "Permit",
  "domain": {"name": "Permit Token", "version": "1", "chainId": $CHAIN_ID, "verifyingContract": "$TOKEN"},
  "message": {"owner": "$owner", "spender": "$VAULT", "value": "$value", "nonce": "$nonce", "deadline": "$DEADLINE"}
}
JSON
    )"
}

# Splits a 65-byte r||s||v signature ($1) into R, S, V globals.
split_sig() {
    R="0x${1:2:64}"
    S="0x${1:66:64}"
    V=$((16#${1:130:2}))
}

DEPOSIT1=250000000000000000000 # 250 PMT
DEPOSIT2=100000000000000000000 # 100 PMT

echo ""
echo "==> Demo 1: permit collapses approve-then-spend into one transaction"
HOLDER=$(cast wallet address "$HOLDER_KEY")
cast send "$TOKEN" "mint(address,uint256)" "$HOLDER" "$DEPOSIT1" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

split_sig "$(sign_permit "$HOLDER_KEY" "$DEPOSIT1")"
echo "    holder signed the permit off-chain; sending the single deposit tx"
cast send "$VAULT" "depositWithPermit(uint256,uint256,uint8,bytes32,bytes32)" \
    "$DEPOSIT1" "$DEADLINE" "$V" "$R" "$S" \
    --rpc-url "$RPC_URL" --private-key "$HOLDER_KEY" > /dev/null
HOLDER_CREDIT=$(cast call "$VAULT" "balances(address)(uint256)" "$HOLDER" --rpc-url "$RPC_URL" | awk '{print $1}')

echo ""
echo "==> Demo 2: fully gasless deposit from a fresh zero-ETH wallet"
WALLET_OUT=$(cast wallet new)
USER=$(echo "$WALLET_OUT" | awk '/Address:/ {print $2}')
USER_KEY=$(echo "$WALLET_OUT" | awk '/Private key:/ {print $3}')
echo "    fresh wallet: $USER"

# The user owns tokens but not a single wei of ETH.
cast send "$TOKEN" "mint(address,uint256)" "$USER" "$DEPOSIT2" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
ETH_BEFORE=$(cast balance "$USER" --rpc-url "$RPC_URL")

# Signature #1: the permit (token domain) replacing the approve tx.
split_sig "$(sign_permit "$USER_KEY" "$DEPOSIT2")"
CALLDATA=$(cast calldata "depositWithPermit(uint256,uint256,uint8,bytes32,bytes32)" \
    "$DEPOSIT2" "$DEADLINE" "$V" "$R" "$S")

# Signature #2: the ForwardRequest (forwarder domain) replacing the deposit tx.
FNONCE=$(cast call "$FORWARDER" "nonces(address)(uint256)" "$USER" --rpc-url "$RPC_URL")
FWD_SIG=$(cast wallet sign --private-key "$USER_KEY" --data "$(cat <<JSON
{
  "types": {
    "EIP712Domain": [
      {"name": "name", "type": "string"},
      {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"},
      {"name": "verifyingContract", "type": "address"}
    ],
    "ForwardRequest": [
      {"name": "from", "type": "address"},
      {"name": "to", "type": "address"},
      {"name": "value", "type": "uint256"},
      {"name": "gas", "type": "uint256"},
      {"name": "nonce", "type": "uint256"},
      {"name": "data", "type": "bytes"}
    ]
  },
  "primaryType": "ForwardRequest",
  "domain": {"name": "MinimalForwarder", "version": "1", "chainId": $CHAIN_ID, "verifyingContract": "$FORWARDER"},
  "message": {"from": "$USER", "to": "$VAULT", "value": "0", "gas": "300000", "nonce": "$FNONCE", "data": "$CALLDATA"}
}
JSON
)")

REQUEST="($USER,$VAULT,0,300000,$FNONCE,$CALLDATA)"
VERIFIED=$(cast call "$FORWARDER" \
    "verify((address,address,uint256,uint256,uint256,bytes),bytes)(bool)" \
    "$REQUEST" "$FWD_SIG" --rpc-url "$RPC_URL")

echo "    relayer submits the signed request and pays the gas"
cast send "$FORWARDER" \
    "execute((address,address,uint256,uint256,uint256,bytes),bytes)" \
    "$REQUEST" "$FWD_SIG" \
    --rpc-url "$RPC_URL" --private-key "$RELAYER_KEY" > /dev/null

ETH_AFTER=$(cast balance "$USER" --rpc-url "$RPC_URL")
USER_CREDIT=$(cast call "$VAULT" "balances(address)(uint256)" "$USER" --rpc-url "$RPC_URL" | awk '{print $1}')
USER_TOKENS=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$USER" --rpc-url "$RPC_URL" | awk '{print $1}')

echo ""
echo "==> Verifying"
FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}

check "holder credited by single-tx permit deposit" "$DEPOSIT1" "$HOLDER_CREDIT"
check "forwarder verified the signed request" "true" "$VERIFIED"
check "fresh user credited by gasless deposit" "$DEPOSIT2" "$USER_CREDIT"
check "fresh user's tokens moved into the vault" "0" "$USER_TOKENS"
check "fresh user held zero ETH throughout" "0:0" "$ETH_BEFORE:$ETH_AFTER"
echo "    vault credit: $(cast from-wei "$USER_CREDIT") PMT to $USER, gas paid by relayer"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Gasless stack verified: all checks passed"
else
    echo "==> Gasless stack verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
