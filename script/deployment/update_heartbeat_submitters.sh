#!/usr/bin/env bash
set -euo pipefail

# Manage HEARTBEAT_SUBMITTER_ROLE membership on a HeartbeatManager.
#
# Required:
#   L2_RPC_URL=...               RPC endpoint
#   HEARTBEAT_MANAGER_ADDRESS=...  HeartbeatManager address
#
# Required unless DRY_RUN=1:
#   PRIVATE_KEY=...              Signer with HEARTBEAT_SUBMITTER_ADMIN_ROLE
#
# Provide address lists (comma/space/newline separated) or files (one per line).
#   GRANT_ADDRESSES=...          Addresses to grant
#   REVOKE_ADDRESSES=...         Addresses to revoke
#   GRANT_FILE=path              File with addresses to grant
#   REVOKE_FILE=path             File with addresses to revoke
#
# Modes:
#   MODE=grant|revoke|both        (default: both)
#
# Behavior flags:
#   DRY_RUN=1                    Print transactions instead of sending
#   CHECK_BEFORE=0               Skip hasRole checks (faster, no skips)
#   ROLE_ID=0x...                Override role id (skip on-chain fetch)

usage() {
  cat <<'EOF'
Usage:
  L2_RPC_URL=... HEARTBEAT_MANAGER_ADDRESS=... PRIVATE_KEY=... \
    MODE=both GRANT_FILE=... REVOKE_FILE=... \
    ./scripts/update_heartbeat_submitters.sh

Examples:
  MODE=grant GRANT_ADDRESSES="0xabc...,0xdef..." \
    ./scripts/update_heartbeat_submitters.sh

  MODE=revoke REVOKE_FILE=./old_submitters.txt DRY_RUN=1 \
    ./scripts/update_heartbeat_submitters.sh
EOF
}

: "${L2_RPC_URL:?L2_RPC_URL is required}"
: "${HEARTBEAT_MANAGER_ADDRESS:?HEARTBEAT_MANAGER_ADDRESS is required}"

MODE="${MODE:-both}"
CHECK_BEFORE="${CHECK_BEFORE:-1}"
DRY_RUN="${DRY_RUN:-0}"

if [[ "$DRY_RUN" != "1" ]]; then
  : "${PRIVATE_KEY:?PRIVATE_KEY is required unless DRY_RUN=1}"
fi

if [[ "$MODE" != "both" && "$MODE" != "grant" && "$MODE" != "revoke" ]]; then
  echo "Invalid MODE: $MODE (expected: grant, revoke, or both)" >&2
  usage
  exit 1
fi

read_list() {
  local label="$1"
  local list_var="$2"
  local file_var="$3"
  local -n out_ref="$4"
  local data=""

  if [[ -n "${file_var:-}" ]]; then
    if [[ ! -f "$file_var" ]]; then
      echo "$label file not found: $file_var" >&2
      exit 1
    fi
    # Allow comments and blank lines.
    data+=" $(awk 'NF && $1 !~ /^#/' "$file_var")"
  fi

  if [[ -n "${list_var:-}" ]]; then
    data+=" $list_var"
  fi

  data="${data//,/ }"
  data="${data//$'\n'/ }"
  data="${data//$'\r'/ }"
  data="${data//$'\t'/ }"

  for addr in $data; do
    if [[ ! "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
      echo "Invalid address in $label list: $addr" >&2
      exit 1
    fi
    out_ref+=("$addr")
  done
}

dedupe_list() {
  local -n in_ref="$1"
  local -n out_ref="$2"
  declare -A seen=()
  for addr in "${in_ref[@]}"; do
    local key="${addr,,}"
    if [[ -z "${seen[$key]+x}" ]]; then
      out_ref+=("$addr")
      seen[$key]=1
    fi
  done
}

role="${ROLE_ID:-}"
if [[ -z "$role" ]]; then
  role=$(cast call --rpc-url "$L2_RPC_URL" \
    "$HEARTBEAT_MANAGER_ADDRESS" "HEARTBEAT_SUBMITTER_ROLE()(bytes32)" | awk '{print $1}')
fi

if [[ -z "$role" || "$role" == "0x" ]]; then
  echo "Failed to resolve HEARTBEAT_SUBMITTER_ROLE" >&2
  exit 1
fi

revoke_raw=()
grant_raw=()

if [[ "$MODE" == "both" || "$MODE" == "revoke" ]]; then
  read_list "revoke" "${REVOKE_ADDRESSES:-}" "${REVOKE_FILE:-}" revoke_raw
fi

if [[ "$MODE" == "both" || "$MODE" == "grant" ]]; then
  read_list "grant" "${GRANT_ADDRESSES:-}" "${GRANT_FILE:-}" grant_raw
fi

revoke_list=()
grant_list=()

dedupe_list revoke_raw revoke_list
dedupe_list grant_raw grant_list

if [[ "$MODE" == "revoke" && ${#revoke_list[@]} -eq 0 ]]; then
  echo "No revoke addresses provided." >&2
  usage
  exit 1
fi
if [[ "$MODE" == "grant" && ${#grant_list[@]} -eq 0 ]]; then
  echo "No grant addresses provided." >&2
  usage
  exit 1
fi
if [[ "$MODE" == "both" && ${#revoke_list[@]} -eq 0 && ${#grant_list[@]} -eq 0 ]]; then
  echo "No addresses provided for grant or revoke." >&2
  usage
  exit 1
fi

maybe_send() {
  local action="$1"
  local addr="$2"

  if [[ "$CHECK_BEFORE" == "1" ]]; then
    local has
    has=$(cast call --rpc-url "$L2_RPC_URL" \
      "$HEARTBEAT_MANAGER_ADDRESS" "hasRole(bytes32,address)(bool)" "$role" "$addr" | awk '{print $1}')
    if [[ "$action" == "revoke" && "$has" != "true" ]]; then
      echo "skip revoke (not a member): $addr"
      return 0
    fi
    if [[ "$action" == "grant" && "$has" == "true" ]]; then
      echo "skip grant (already a member): $addr"
      return 0
    fi
  fi

  local func
  if [[ "$action" == "revoke" ]]; then
    func="revokeRole(bytes32,address)"
  else
    func="grantRole(bytes32,address)"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "cast send --rpc-url '$L2_RPC_URL' --private-key '***' '$HEARTBEAT_MANAGER_ADDRESS' '$func' '$role' '$addr'"
    return 0
  fi

  cast send --rpc-url "$L2_RPC_URL" --private-key "$PRIVATE_KEY" \
    "$HEARTBEAT_MANAGER_ADDRESS" "$func" "$role" "$addr"
}

echo "HeartbeatManager: $HEARTBEAT_MANAGER_ADDRESS"
echo "HEARTBEAT_SUBMITTER_ROLE: $role"

echo "Mode: $MODE"

if [[ "$MODE" == "both" || "$MODE" == "revoke" ]]; then
  echo "Revoking ${#revoke_list[@]} addresses..."
  for addr in "${revoke_list[@]}"; do
    maybe_send revoke "$addr"
  done
fi

if [[ "$MODE" == "both" || "$MODE" == "grant" ]]; then
  echo "Granting ${#grant_list[@]} addresses..."
  for addr in "${grant_list[@]}"; do
    maybe_send grant "$addr"
  done
fi

if [[ "$DRY_RUN" != "1" ]]; then
  echo "Done. Consider spot-checking hasRole on a few addresses."
fi
