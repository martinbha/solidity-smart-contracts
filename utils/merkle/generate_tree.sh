#!/usr/bin/env bash
#
# generate_tree.sh — build the airdrop Merkle tree off-chain.
#
# Reads utils/merkle/recipients.json and writes deployments/merkle/tree.json
# (root + a proof per recipient). Pure computation: no node, no transactions.
# Edit recipients.json to change the drop, then re-run.
#
# Usage: ./utils/merkle/generate_tree.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

mkdir -p deployments/merkle

echo "==> Generating Merkle tree from utils/merkle/recipients.json"
forge script script/merkle/GenerateMerkleTree.s.sol:GenerateMerkleTree | grep -E "MERKLE_ROOT|RECIPIENT_COUNT|TOTAL_AMOUNT|written"
