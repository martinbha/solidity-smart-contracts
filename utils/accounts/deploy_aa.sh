#!/usr/bin/env bash
#
# deploy_aa.sh — deploy the ERC-4337 stack (EntryPoint, account factory,
# sponsor paymaster, a demo target) and drive one gasless UserOperation end
# to end:
#
#   build a UserOp from a fresh owner whose smart account holds ZERO ETH and
#     does not yet exist on chain; its initCode deploys it on first use
#   the paymaster (allowlisted for the target) sponsors the gas; a bundler
#     submits the signed op through EntryPoint.handleOps
#
# Verifies the target action executed, the account was deployed
# counterfactually, and the sender account paid zero ETH the whole time.
#
# Usage: ./utils/accounts/deploy_aa.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && source .env

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Anvil dev account #0 (deployer + bundler). Public key, local only.
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
# Anvil dev account #1: the smart account's owner/signer.
OWNER_KEY="${OWNER_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
OWNER=$(cast wallet address "$OWNER_KEY")
BUNDLER=$(cast wallet address "$PRIVATE_KEY")

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying ERC-4337 stack to chain $CHAIN_ID"
# The optimized profile: the canonical EntryPoint exceeds 24KB unoptimized.
OUTPUT=$(FOUNDRY_PROFILE=optimized forge script \
    script/accounts/DeploySmartAccount.s.sol:DeploySmartAccount \
    --rpc-url "$RPC_URL" --broadcast)

parse_addr() { echo "$OUTPUT" | grep -Eo "$1: 0x[0-9a-fA-F]{40}" | awk '{print $2}'; }
ENTRY_POINT=$(parse_addr "ENTRY_POINT")
FACTORY=$(parse_addr "FACTORY")
PAYMASTER=$(parse_addr "PAYMASTER")
TARGET=$(parse_addr "TARGET")

if [ -z "$ENTRY_POINT" ] || [ -z "$FACTORY" ] || [ -z "$PAYMASTER" ] || [ -z "$TARGET" ]; then
    echo "error: could not parse deploy addresses from forge output" >&2
    exit 1
fi

DEPLOYMENT_FILE="deployments/accounts/aa.${CHAIN_ID}.env"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")"
cat > "$DEPLOYMENT_FILE" <<EOF
ENTRY_POINT=$ENTRY_POINT
FACTORY=$FACTORY
PAYMASTER=$PAYMASTER
TARGET=$TARGET
EOF
echo "    entryPoint: $ENTRY_POINT"
echo "    factory:    $FACTORY"
echo "    paymaster:  $PAYMASTER"
echo "    target:     $TARGET"

SALT=0
ACCOUNT=$(cast call "$FACTORY" "getAddress(address,uint256)(address)" "$OWNER" "$SALT" \
    --rpc-url "$RPC_URL")
echo ""
echo "==> Counterfactual account for owner $OWNER"
echo "    address:    $ACCOUNT (code size: $(cast codesize "$ACCOUNT" --rpc-url "$RPC_URL"))"

# --- Build the UserOperation fields ------------------------------------------

# initCode = factory address ++ createAccount(owner, salt) calldata; deploys
# the account on first use.
CREATE_CALL=$(cast calldata "createAccount(address,uint256)" "$OWNER" "$SALT")
INIT_CODE="0x${FACTORY#0x}${CREATE_CALL#0x}"

# callData = execute(target, 0, ping())
PING=$(cast calldata "ping()")
CALL_DATA=$(cast calldata "execute(address,uint256,bytes)" "$TARGET" 0 "$PING")

NONCE=$(cast call "$ENTRY_POINT" "getNonce(address,uint192)(uint256)" "$ACCOUNT" 0 \
    --rpc-url "$RPC_URL" | awk '{print $1}')

# Packed gas fields. accountGasLimits = verificationGasLimit(16B) ++
# callGasLimit(16B); verification must cover the account deployment too.
GAS_LIMITS="0x$(printf '%032x%032x' 2000000 400000)"
# gasFees = maxPriorityFeePerGas(16B) ++ maxFeePerGas(16B), both 1 gwei.
GAS_FEES="0x$(printf '%032x%032x' 1000000000 1000000000)"
PRE_VER_GAS=100000
# paymasterAndData = paymaster ++ verificationGasLimit(16B) ++ postOpGasLimit(16B)
PM_DATA="0x${PAYMASTER#0x}$(printf '%032x%032x' 200000 100000)"

OP_TYPE="(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)"
# The op with an empty signature, for hashing.
unsigned_op() {
    echo "($ACCOUNT,$NONCE,$INIT_CODE,$CALL_DATA,$GAS_LIMITS,$PRE_VER_GAS,$GAS_FEES,$PM_DATA,0x)"
}

# getUserOpHash binds the op to this EntryPoint + chain id (signature field
# excluded), so the owner's signature over it can't be replayed elsewhere.
USER_OP_HASH=$(cast call "$ENTRY_POINT" "getUserOpHash($OP_TYPE)(bytes32)" \
    "$(unsigned_op)" --rpc-url "$RPC_URL")
echo ""
echo "==> Signing the UserOp as the owner (no ETH required)"
echo "    userOpHash: $USER_OP_HASH"
# --no-hash: sign the 32-byte digest directly; the account recovers over it raw.
SIGNATURE=$(cast wallet sign --no-hash --private-key "$OWNER_KEY" "$USER_OP_HASH")

SIGNED_OP="($ACCOUNT,$NONCE,$INIT_CODE,$CALL_DATA,$GAS_LIMITS,$PRE_VER_GAS,$GAS_FEES,$PM_DATA,$SIGNATURE)"

# --- Submit through the bundler ----------------------------------------------

echo ""
echo "==> Bundler submits handleOps; paymaster sponsors the gas"
ACCOUNT_ETH_BEFORE=$(cast balance "$ACCOUNT" --rpc-url "$RPC_URL")
PM_DEPOSIT_BEFORE=$(cast call "$ENTRY_POINT" "balanceOf(address)(uint256)" "$PAYMASTER" \
    --rpc-url "$RPC_URL" | awk '{print $1}')

cast send "$ENTRY_POINT" "handleOps(${OP_TYPE}[],address)" "[$SIGNED_OP]" "$BUNDLER" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null

ACCOUNT_ETH_AFTER=$(cast balance "$ACCOUNT" --rpc-url "$RPC_URL")
PM_DEPOSIT_AFTER=$(cast call "$ENTRY_POINT" "balanceOf(address)(uint256)" "$PAYMASTER" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
PINGS=$(cast call "$TARGET" "pings()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
ACCOUNT_CODESIZE=$(cast codesize "$ACCOUNT" --rpc-url "$RPC_URL")

echo ""
echo "==> Verifying"
FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}

check "target action executed (pings == 1)" "1" "$PINGS"
check "account deployed counterfactually" "true" "$([ "$ACCOUNT_CODESIZE" -gt 0 ] && echo true || echo false)"
check "sender account held zero ETH throughout" "0:0" "$ACCOUNT_ETH_BEFORE:$ACCOUNT_ETH_AFTER"
# bc: deposit amounts exceed shell integer math.
check "paymaster deposit paid the gas" "1" "$(echo "$PM_DEPOSIT_BEFORE > $PM_DEPOSIT_AFTER" | bc)"
echo "    paymaster deposit: $(cast from-wei "$PM_DEPOSIT_BEFORE") -> $(cast from-wei "$PM_DEPOSIT_AFTER") ETH"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Account abstraction verified: all checks passed"
else
    echo "==> Account abstraction verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
