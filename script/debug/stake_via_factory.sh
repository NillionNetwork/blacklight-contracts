#!/usr/bin/env bash
set -euo pipefail

# Stake through NodeOperatorFactory from a user address that holds TEST tokens.
#
# Required env vars:
#   RPC_URL
#   PRIVATE_KEY
#   NODE_OPERATOR_FACTORY
#   AMOUNT_RAW          # token amount in raw units (TEST has 6 decimals by default)
#
# Optional:
#   AUTO_APPROVE=true   # default true; sends approve(factory, AMOUNT_RAW) before staking
#
# Example:
#   export RPC_URL=http://127.0.0.1:8545
#   export PRIVATE_KEY=0x...
#   export NODE_OPERATOR_FACTORY=0x...
#   export AMOUNT_RAW=10000000   # 10 TEST with 6 decimals
#   ./script/debug/stake_via_factory.sh

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command not found: $1" >&2
    exit 1
  }
}

require_cmd cast

normalize_uint() {
  local v="${1:-}"
  v="$(echo "$v" | tr -d '[:space:]')"
  if [[ -z "$v" ]]; then
    echo "0"
    return
  fi
  if [[ "$v" =~ ^0x[0-9a-fA-F]+$ ]]; then
    cast to-dec "$v" 2>/dev/null || echo "0"
    return
  fi
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
    return
  fi
  echo "0"
}

RPC_URL="${RPC_URL:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"
NODE_OPERATOR_FACTORY="${NODE_OPERATOR_FACTORY:-}"
AMOUNT_RAW="${AMOUNT_RAW:-}"
AUTO_APPROVE="${AUTO_APPROVE:-true}"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is required" >&2
  exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
  echo "Error: PRIVATE_KEY is required" >&2
  exit 1
fi

if [ -z "$NODE_OPERATOR_FACTORY" ]; then
  echo "Error: NODE_OPERATOR_FACTORY is required" >&2
  exit 1
fi

if [ -z "$AMOUNT_RAW" ] || ! [[ "$AMOUNT_RAW" =~ ^[0-9]+$ ]] || [ "$AMOUNT_RAW" = "0" ]; then
  echo "Error: AMOUNT_RAW must be a non-zero integer" >&2
  exit 1
fi

USER_ADDRESS="$(cast wallet address --private-key "$PRIVATE_KEY")"
STAKE_TOKEN="$(cast call "$NODE_OPERATOR_FACTORY" 'token()(address)' --rpc-url "$RPC_URL")"
STAKING_OPERATORS="$(cast call "$NODE_OPERATOR_FACTORY" 'stakingOperators()(address)' --rpc-url "$RPC_URL")"
SYMBOL="$(cast call "$STAKE_TOKEN" 'symbol()(string)' --rpc-url "$RPC_URL" 2>/dev/null || echo "TEST")"
SYMBOL="${SYMBOL%\"}"
SYMBOL="${SYMBOL#\"}"
PENDING_NONCE="$(cast nonce "$USER_ADDRESS" --block pending --rpc-url "$RPC_URL" 2>/dev/null || cast nonce "$USER_ADDRESS" --rpc-url "$RPC_URL")"

echo "User: $USER_ADDRESS"
echo "Factory: $NODE_OPERATOR_FACTORY"
echo "Stake token: $STAKE_TOKEN ($SYMBOL)"
echo "Amount raw: $AMOUNT_RAW"
echo "Pending nonce: $PENDING_NONCE"

if [ "$AUTO_APPROVE" = "true" ]; then
  echo "Approving factory to spend $AMOUNT_RAW $SYMBOL (raw)..."
  cast send "$STAKE_TOKEN" \
    "approve(address,uint256)" \
    "$NODE_OPERATOR_FACTORY" \
    "$AMOUNT_RAW" \
    --nonce "$PENDING_NONCE" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    >/dev/null
fi

echo "Staking through factory..."
STAKE_NONCE="$PENDING_NONCE"
if [ "$AUTO_APPROVE" = "true" ]; then
  STAKE_NONCE="$((PENDING_NONCE + 1))"
fi
if ! cast send "$NODE_OPERATOR_FACTORY" \
  "stake(uint256)" \
  "$AMOUNT_RAW" \
  --nonce "$STAKE_NONCE" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  >/dev/null; then
  echo "Error: stake() transaction failed. Check allowance, TEST balance, min stake, and free-node availability." >&2
  exit 1
fi

NODE_OPERATOR="$(cast call "$NODE_OPERATOR_FACTORY" 'userToOperator(address)(address)' "$USER_ADDRESS" --rpc-url "$RPC_URL")"
NODE_ADDRESS="$(cast call "$NODE_OPERATOR_FACTORY" 'userToNode(address)(address)' "$USER_ADDRESS" --rpc-url "$RPC_URL")"
if [[ "$NODE_OPERATOR" =~ ^0x0+$ ]] || [[ "$NODE_ADDRESS" =~ ^0x0+$ ]]; then
  echo "Error: user was not bound to a node/operator after staking." >&2
  echo "userToOperator=$NODE_OPERATOR userToNode=$NODE_ADDRESS" >&2
  exit 1
fi

NODE_STAKE_OUT="$(cast call "$STAKING_OPERATORS" 'stakeOf(address)(uint256)' "$NODE_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || true)"
NODE_STAKE_RAW="$(normalize_uint "$NODE_STAKE_OUT")"
USER_TOKEN_BAL_OUT="$(cast call "$STAKE_TOKEN" 'balanceOf(address)(uint256)' "$USER_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || true)"
USER_TOKEN_BAL_RAW="$(normalize_uint "$USER_TOKEN_BAL_OUT")"

echo ""
echo "Done."
echo "Assigned node: $NODE_ADDRESS"
echo "Assigned node manager: $NODE_OPERATOR"
echo "Node stake (raw): $NODE_STAKE_RAW"
echo "User $SYMBOL balance (raw): $USER_TOKEN_BAL_RAW"
