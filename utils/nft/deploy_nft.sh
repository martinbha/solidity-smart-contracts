#!/usr/bin/env bash
#
# deploy_nft.sh — deploy the fully on-chain generative NFT and prove the art
# really lives on the chain:
#
#   deployer, alice, bob (Anvil #0-#2) each mint one canvas for 0.001 ETH
#   each tokenURI is pulled with cast call, base64-decoded twice
#     (JSON envelope, then the SVG inside its image field)
#   the decoded .svg files land in deployments/nft/ — open them in a browser
#
# Verifies every URI is a well-formed data:application/json;base64 envelope,
# the JSON parses with the expected name, the image decodes to real SVG
# markup, and the three seeds produce three different pieces of art.
#
# Usage: ./utils/nft/deploy_nft.sh

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

if ! command -v python3 > /dev/null; then
    echo "error: python3 is required to decode base64 data URIs" >&2
    exit 1
fi

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
    echo "error: no node reachable at $RPC_URL (start one with 'anvil', or set RPC_URL in .env)" >&2
    exit 1
fi

echo "==> Deploying chain canvas to chain $CHAIN_ID"
OUTPUT=$(forge script script/nft/DeployChainCanvas.s.sol:DeployChainCanvas \
    --rpc-url "$RPC_URL" --broadcast)

CANVAS=$(echo "$OUTPUT" | grep -Eo "CHAIN_CANVAS: 0x[0-9a-fA-F]{40}" | awk '{print $2}')
if [ -z "$CANVAS" ]; then
    echo "error: could not parse deploy address from forge output" >&2
    exit 1
fi

OUT_DIR="deployments/nft"
mkdir -p "$OUT_DIR"
cat > "$OUT_DIR/canvas.${CHAIN_ID}.env" <<EOF
CHAIN_CANVAS=$CANVAS
EOF
echo "    canvas: $CANVAS"

echo ""
echo "==> Minting three canvases (0.001 ETH each)"
for KEY in "$PRIVATE_KEY" "$ALICE_KEY" "$BOB_KEY"; do
    cast send "$CANVAS" "mint()" --value 0.001ether \
        --rpc-url "$RPC_URL" --private-key "$KEY" > /dev/null
done
echo "    minted tokens #1 #2 #3"

echo ""
echo "==> Decoding tokenURIs into $OUT_DIR/"
FAILURES=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "    PASS  $label"
    else echo "    FAIL  $label: expected $expected, got $actual"; FAILURES=$((FAILURES + 1)); fi
}

JSON_PREFIX="data:application/json;base64,"
for ID in 1 2 3; do
    URI=$(cast call "$CANVAS" "tokenURI(uint256)(string)" "$ID" --rpc-url "$RPC_URL" \
        | sed -e 's/^"//' -e 's/"$//')

    case "$URI" in
        "$JSON_PREFIX"*) check "token #$ID URI is a base64 JSON data URI" "1" "1" ;;
        *) check "token #$ID URI is a base64 JSON data URI" "1" "0"; continue ;;
    esac

    # Decode the JSON envelope, verify it, then decode the SVG inside it.
    # Prints "<name>|<traits>" on success so the shell can assert on them.
    SUMMARY=$(printf '%s' "${URI#"$JSON_PREFIX"}" | python3 -c '
import base64, json, sys

meta = json.loads(base64.b64decode(sys.stdin.read()))
image = meta["image"]
prefix = "data:image/svg+xml;base64,"
assert image.startswith(prefix), "image is not a base64 SVG data URI"
svg = base64.b64decode(image[len(prefix):]).decode()
assert svg.startswith("<svg"), "decoded image is not SVG markup"
with open(sys.argv[1], "w") as f:
    f.write(svg)
traits = ",".join("{}={}".format(a["trait_type"], a["value"]) for a in meta["attributes"])
print(meta["name"] + "|" + traits)
' "$OUT_DIR/canvas-$ID.svg")

    NAME="${SUMMARY%%|*}"
    TRAITS="${SUMMARY#*|}"
    check "token #$ID JSON parses with the right name" "Chain Canvas #$ID" "$NAME"
    echo "          traits: $TRAITS"
    echo "          art:    $OUT_DIR/canvas-$ID.svg"
done

echo ""
echo "==> Verifying the art"
for ID in 1 2 3; do
    check "canvas-$ID.svg is non-empty" "1" "$([ -s "$OUT_DIR/canvas-$ID.svg" ] && echo 1 || echo 0)"
done
# Different minters guarantee different seeds, which must yield different art.
check "tokens 1 and 2 render differently" "1" "$(cmp -s "$OUT_DIR/canvas-1.svg" "$OUT_DIR/canvas-2.svg" && echo 0 || echo 1)"
check "tokens 2 and 3 render differently" "1" "$(cmp -s "$OUT_DIR/canvas-2.svg" "$OUT_DIR/canvas-3.svg" && echo 0 || echo 1)"
check "mint fees escrowed in the contract" "3000000000000000" \
    "$(cast balance "$CANVAS" --rpc-url "$RPC_URL")"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "==> Chain canvas verified: all checks passed (open the .svg files in a browser!)"
else
    echo "==> Chain canvas verification FAILED ($FAILURES check(s))" >&2
    exit 1
fi
