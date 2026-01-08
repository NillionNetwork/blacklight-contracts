#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Anvil Startup Script with Contract Deployment and Account Funding
# =============================================================================
#
# Usage:
#   ./start-anvil.sh [OPTIONS] [-- ANVIL_ARGS...]
#
# Options:
#   -H, --host HOST        Host to bind anvil (default: 0.0.0.0)
#   -p, --port PORT        Port for anvil RPC (default: 8545)
#   -c, --chain-id ID      Chain ID (default: 31337)
#   -m, --mnemonic PHRASE  Mnemonic for account generation (default: anvil's default)
#   -b, --block-time SECS  Block time in seconds, 0 for instant (default: 2)
#   -a, --accounts NUM     Number of accounts to create (default: 10)
#   -t, --fund-tokens AMT  Tokens to fund each operator (default: 10)
#   -e, --fund-eth AMT     ETH to fund each operator (default: 10)
#   --skip-funding         Skip funding operators entirely
#   -h, --help             Show this help message
#
# Any arguments after -- are passed directly to anvil:
#   ./start-anvil.sh --port 9545 -- --gas-limit 30000000 --silent
#
# Examples:
#   ./start-anvil.sh                              # Use defaults
#   ./start-anvil.sh --block-time 0               # Instant mining (fastest)
#   ./start-anvil.sh --accounts 5                 # Fewer accounts
#   ./start-anvil.sh -- --gas-limit 30000000      # Extra anvil args
#
# =============================================================================

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
ANVIL_HOST="0.0.0.0"
ANVIL_PORT="8545"
CHAIN_ID="31337"
MNEMONIC="test test test test test test test test test test test junk"
BLOCK_TIME="2"
NUM_ACCOUNTS="10"
FUND_TOKENS="10"
FUND_ETH="10"
SKIP_FUNDING="false"

# Extra arguments to pass to anvil
EXTRA_ARGS=()

# Help function
show_help() {
  head -n 35 "$0" | tail -n +2 | sed 's/^# //' | sed 's/^#//'
  exit 0
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) # Host to bind anvil (default: 0.0.0.0)
      ANVIL_HOST="$2"
      shift 2
      ;;
    -p|--port) # Port for anvil RPC (default: 8545)
      ANVIL_PORT="$2"
      shift 2
      ;;
    -c|--chain-id) # Chain ID (default: 31337)
      CHAIN_ID="$2"
      shift 2
      ;;
    -m|--mnemonic) # Mnemonic for account generation (default: anvil's default)
      MNEMONIC="$2"
      shift 2
      ;;
    -b|--block-time) # Block time in seconds, 0 for instant (default: 2)
      BLOCK_TIME="$2"
      shift 2
      ;;
    -a|--accounts) # Number of accounts to create (default: 10)
      NUM_ACCOUNTS="$2"
      shift 2
      ;;
    -t|--fund-tokens) # Tokens to fund each operator (default: 10)
      FUND_TOKENS="$2"
      shift 2
      ;;
    -e|--fund-eth) # ETH to fund each operator (default: 10)
      FUND_ETH="$2"
      shift 2
      ;;
    --skip-funding) # Skip funding operators entirely
      SKIP_FUNDING="true"
      shift
      ;;
    -h|--help)
      show_help
      ;;
    --)
      shift
      EXTRA_ARGS=("$@")
      break
      ;;
    -*)
      echo -e "${RED}Error:${NC} Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
    *)
      echo -e "${RED}Error:${NC} Unexpected argument: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

RPC_URL="http://127.0.0.1:${ANVIL_PORT}"

# Start anvil in background
if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
  anvil \
    --host "$ANVIL_HOST" \
    --port "$ANVIL_PORT" \
    --chain-id "$CHAIN_ID" \
    --mnemonic "$MNEMONIC" \
    --block-time "$BLOCK_TIME" \
    --accounts "$NUM_ACCOUNTS" \
    "${EXTRA_ARGS[@]}" &
else
  anvil \
    --host "$ANVIL_HOST" \
    --port "$ANVIL_PORT" \
    --chain-id "$CHAIN_ID" \
    --mnemonic "$MNEMONIC" \
    --block-time "$BLOCK_TIME" \
    --accounts "$NUM_ACCOUNTS" &
fi
ANVIL_PID=$!

# Wait for RPC to be ready
MAX_RETRIES=30
RETRY_COUNT=0
until cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo -e "${RED}Error:${NC} Anvil failed to start after ${MAX_RETRIES} retries"
    kill $ANVIL_PID 2>/dev/null || true
    exit 1
  fi
  sleep 0.5
done

# Get deployer private key (account 0)
DEPLOYER_PRIVATE_KEY="0x$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 0 | sed 's/^0x//')"
DEPLOYER_ADDRESS=$(cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index 0)

# Deploy contracts

export RPC_URL
export PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY"

bash ./script/deploy_sc.sh

# Fund and stake for operators (accounts 1 to NUM_ACCOUNTS-1)
if [ "$SKIP_FUNDING" != "true" ] && [ "$NUM_ACCOUNTS" -gt 1 ]; then
  # Source contract addresses
  if [ ! -f "contract_addresses.env" ]; then
    echo -e "${RED}Error:${NC} contract_addresses.env not found"
    exit 1
  fi
  source contract_addresses.env
  
  STAKE_TOKEN_ADDRESS="${STAKE_TOKEN:-${STAKE_TOKEN_ADDRESS:-}}"
  STAKING_OPS_ADDRESS="${STAKING_OPERATORS:-}"
  
  if [ -z "${STAKE_TOKEN_ADDRESS:-}" ]; then
    echo -e "${RED}Error:${NC} STAKE_TOKEN not found in contract_addresses.env"
    exit 1
  fi
  
  if [ -z "${STAKING_OPS_ADDRESS:-}" ]; then
    echo -e "${RED}Error:${NC} STAKING_OPERATORS not found in contract_addresses.env"
    exit 1
  fi
  
  # Convert amounts to wei
  TOKEN_AMOUNT_WEI="${FUND_TOKENS}000000"           # 6 decimals
  ETH_AMOUNT_WEI="${FUND_ETH}000000000000000000"    # 18 decimals

  # Fund and stake using the Solidity script
  PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
  MNEMONIC="$MNEMONIC" \
  STAKE_TOKEN="$STAKE_TOKEN_ADDRESS" \
  STAKING_OPERATORS="$STAKING_OPS_ADDRESS" \
  NUM_OPERATORS="$NUM_ACCOUNTS" \
  TOKEN_AMOUNT="$TOKEN_AMOUNT_WEI" \
  ETH_AMOUNT="$ETH_AMOUNT_WEI" \
  forge script script/FundOperators.s.sol:FundOperators \
    --rpc-url "$RPC_URL" \
    --broadcast
fi

echo "RPC: ${RPC_URL} | Deployer: ${DEPLOYER_ADDRESS}"

# Keep anvil running in foreground
wait $ANVIL_PID
