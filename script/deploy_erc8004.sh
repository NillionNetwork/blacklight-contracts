#!/usr/bin/env bash
set -euo pipefail

# Deploy ERC-8004 registry contracts to local Anvil or remote RPC
# Usage: ./script/deploy_erc8004.sh
#
# Environment variables:
#   RPC_URL          - RPC endpoint (default: http://127.0.0.1:8545)
#   PRIVATE_KEY      - Deployer private key (default: Anvil account 0)
#   HEARTBEAT_MANAGER - HeartbeatManager address to connect (optional)
#   DEPLOY_REPUTATION - Set to "false" to skip ReputationRegistry (default: true)
#   SKIP_HEARTBEAT_ROLE - Set to "true" to skip granting submitter role (default: false)
#
# Deploys:
#   - IdentityRegistryUpgradeable (ERC721 identity NFT)
#   - ValidationRegistryUpgradeable (validation registry)
#   - ReputationRegistryUpgradeable (reputation/feedback registry)
#
# Outputs contract addresses to: erc8004_addresses.env

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Defaults (Anvil account 0)
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

echo -e "${BLUE}ERC-8004 Deployment Script${NC}"
echo "RPC URL: $RPC_URL"

# Check RPC is available
if ! curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$RPC_URL" > /dev/null 2>&1; then
  echo -e "${RED}Error:${NC} RPC endpoint is not available at ${RPC_URL}"
  echo "If using Anvil, start it with: anvil"
  exit 1
fi

# Build contracts
echo -e "\n${BLUE}Building contracts...${NC}"
forge build

# Deploy contracts
echo -e "\n${BLUE}Deploying ERC-8004 contracts...${NC}"
export RPC_URL
export PRIVATE_KEY
export HEARTBEAT_MANAGER="${HEARTBEAT_MANAGER:-}"
export DEPLOY_REPUTATION="${DEPLOY_REPUTATION:-true}"
export SKIP_HEARTBEAT_ROLE="${SKIP_HEARTBEAT_ROLE:-false}"

forge script script/DeployERC8004.s.sol:DeployERC8004 \
  --rpc-url "$RPC_URL" \
  --broadcast

# Display addresses
echo -e "\n${GREEN}Deployment successful!${NC}"
if [ -f "erc8004_addresses.env" ]; then
  echo -e "\n${BLUE}Contract Addresses:${NC}"
  cat erc8004_addresses.env | grep -v "^#" | grep "=" || true
else
  echo -e "${RED}Error:${NC} erc8004_addresses.env was not generated"
  exit 1
fi
