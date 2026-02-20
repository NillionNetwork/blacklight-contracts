#!/usr/bin/env bash
set -euo pipefail

# Lists addresses that hold ETH and/or StakeToken.
#
# Scope note:
# - "All holders" is only as complete as the candidate set.
# - Candidate set here is:
#   1) addresses derived from MNEMONIC for indices [0..NUM_ACCOUNTS-1]
#   2) all from/to addresses seen in StakeToken Transfer logs in [FROM_BLOCK..TO_BLOCK]
#
# Required env vars:
#   RPC_URL
#   STAKE_TOKEN
#
# Optional env vars:
#   FROM_BLOCK (default: 0)
#   TO_BLOCK (default: latest)
#   MNEMONIC (default: anvil mnemonic)
#   NUM_ACCOUNTS (default: 20)

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command not found: $1" >&2
    exit 1
  }
}

require_cmd cast
require_cmd jq
require_cmd sort
require_cmd awk
require_cmd sed

RPC_URL="${RPC_URL:-}"
STAKE_TOKEN="${STAKE_TOKEN:-}"
FROM_BLOCK="${FROM_BLOCK:-0}"
TO_BLOCK="${TO_BLOCK:-latest}"
MNEMONIC="${MNEMONIC:-test test test test test test test test test test test junk}"
NUM_ACCOUNTS="${NUM_ACCOUNTS:-20}"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is required" >&2
  exit 1
fi

if [ -z "$STAKE_TOKEN" ]; then
  echo "Error: STAKE_TOKEN is required" >&2
  exit 1
fi

if ! [[ "$NUM_ACCOUNTS" =~ ^[0-9]+$ ]]; then
  echo "Error: NUM_ACCOUNTS must be an integer" >&2
  exit 1
fi

tmp_candidates="$(mktemp)"
trap 'rm -f "$tmp_candidates"' EXIT

# 1) Add mnemonic-derived addresses.
for (( i=0; i<NUM_ACCOUNTS; i++ )); do
  cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$i" >> "$tmp_candidates"
done

# 2) Add token transfer participants.
logs_json="$(cast logs \
  --rpc-url "$RPC_URL" \
  --address "$STAKE_TOKEN" \
  --from-block "$FROM_BLOCK" \
  --to-block "$TO_BLOCK" \
  'Transfer(address,address,uint256)' \
  --json)"

if [ "$logs_json" != "[]" ]; then
  echo "$logs_json" | jq -r '.[] | .topics[1], .topics[2] | "0x" + .[26:]' >> "$tmp_candidates"
fi

# Normalize and dedupe; drop zero address.
sort -fu "$tmp_candidates" | awk 'tolower($0)!="0x0000000000000000000000000000000000000000"' > "${tmp_candidates}.uniq"
mv "${tmp_candidates}.uniq" "$tmp_candidates"

# Token metadata for display.
symbol="$(cast call "$STAKE_TOKEN" 'symbol()(string)' --rpc-url "$RPC_URL" 2>/dev/null || echo "STAKE")"
symbol="$(echo "$symbol" | sed 's/^"//; s/"$//')"
decimals_raw="$(cast call "$STAKE_TOKEN" 'decimals()(uint8)' --rpc-url "$RPC_URL" 2>/dev/null || echo "0x12")"
decimals="$(cast to-dec "$decimals_raw" 2>/dev/null || echo "18")"

printf "Scanned candidates: %s\n" "$(wc -l < "$tmp_candidates" | tr -d ' ')"
printf "Stake token: %s (%s, decimals=%s)\n\n" "$STAKE_TOKEN" "$symbol" "$decimals"

printf "%-44s %-22s %-22s\n" "ADDRESS" "ETH" "${symbol}_RAW"
printf "%-44s %-22s %-22s\n" "--------------------------------------------" "----------------------" "----------------------"

while IFS= read -r addr; do
  if ! [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    continue
  fi

  eth_wei="$(cast balance "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")"
  eth_val="$(cast from-wei "$eth_wei" ether 2>/dev/null || echo "0")"

  stake_out="$(cast call "$STAKE_TOKEN" 'balanceOf(address)(uint256)' "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")"
  if [[ "$stake_out" =~ ^0x[0-9a-fA-F]+$ ]]; then
    stake_raw="$(cast to-dec "$stake_out" 2>/dev/null || echo "0")"
  elif [[ "$stake_out" =~ ^[0-9]+$ ]]; then
    stake_raw="$stake_out"
  else
    stake_raw="0"
  fi

  if [ "$eth_wei" != "0" ] || [ "$stake_raw" != "0" ]; then
    printf "%-44s %-22s %-22s\n" "$addr" "$eth_val" "$stake_raw"
  fi
done < "$tmp_candidates"
