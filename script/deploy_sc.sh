#!/usr/bin/env bash
set -euo pipefail

# Deploy the full Blacklight stack to local Anvil
# Usage: ./script/deploy_anvil.sh
#
# Deploys contracts and generates contract_addresses.env

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Anvil defaults (account 0)
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# Check Anvil is running
if ! curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$RPC_URL" > /dev/null 2>&1; then
  echo -e "${RED}Error:${NC} Anvil is not running at ${RPC_URL}"
  exit 1
fi

forge build

# Deploy contracts
export RPC_URL
export PRIVATE_KEY

forge script script/DeployBlacklight.s.sol:DeployBlacklight \
  --rpc-url "$RPC_URL" \
  --broadcast

# Display addresses
if [ -f "contract_addresses.env" ]; then
  cat contract_addresses.env | grep -v "^#" | grep "="
else
  echo -e "${RED}Error:${NC} contract_addresses.env was not generated"
  exit 1
fi
