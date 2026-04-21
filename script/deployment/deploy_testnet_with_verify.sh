#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/deployment/shlib/common.sh
source "$SCRIPT_DIR/shlib/common.sh"
REPO_ROOT="$(repo_root_from_script "${BASH_SOURCE[0]}")"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/target/deploy-testnet}"
STATE_FILE="${STATE_FILE:-$LOG_DIR/addresses.env}"

mkdir -p "$LOG_DIR"

PROFILE=""
PROFILE_JSON=""
OVERRIDES=()
DRY_RUN="0"
RESUME="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --profile-json)
      PROFILE_JSON="$2"
      shift 2
      ;;
    --set)
      OVERRIDES+=("$2")
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    --resume)
      RESUME="1"
      shift
      ;;
    --no-resume)
      RESUME="0"
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./script/deployment/deploy_testnet_with_verify.sh [--profile FILE] [--profile-json FILE] [--set KEY=VALUE] [--dry-run]
Chain ID guards: set EXPECTED_L1_CHAIN_ID and EXPECTED_L2_CHAIN_ID in your profile or via --set.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

load_profile_if_present "$PROFILE"
load_json_profile_if_present "$PROFILE_JSON"
if [[ ${#OVERRIDES[@]} -gt 0 ]]; then
  apply_overrides "${OVERRIDES[@]}"
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_env() {
  if [[ -z "${!1:-}" ]]; then
    echo "Missing required env var: $1" >&2
    exit 1
  fi
}

require_cmd forge
require_cmd cast
require_cmd python3
assert_toolchain

require_env PRIVATE_KEY
require_env L1_RPC_URL
require_env L2_RPC_URL
require_env L1_BRIDGE

ensure_solc() {
  if [[ -x "$SOLC_PATH" ]]; then
    return
  fi
  if [[ "${SKIP_SOLC_DOWNLOAD:-0}" == "1" ]]; then
    echo "Missing solc at $SOLC_PATH and SKIP_SOLC_DOWNLOAD=1" >&2
    exit 1
  fi
  require_cmd curl
  mkdir -p "$(dirname "$SOLC_PATH")"
  local os
  local asset
  os="$(uname -s)"
  case "$os" in
    Darwin) asset="solc-macos" ;;
    Linux) asset="solc-static-linux" ;;
    *) echo "Unsupported OS for solc download: $os" >&2; exit 1 ;;
  esac
  local url="https://github.com/argotorg/solidity/releases/download/v${SOLC_VERSION}/${asset}"
  echo "Downloading solc $SOLC_VERSION..."
  curl -L -o "$SOLC_PATH" "$url"
  chmod +x "$SOLC_PATH"
}

if [[ "${LOAD_STATE:-0}" == "1" && -f "$STATE_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  set +a
fi

if [[ "$RESUME" == "1" && -f "$STATE_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  set +a
fi

L2_BRIDGE="${L2_BRIDGE:-0x4200000000000000000000000000000000000010}"
L2_CHAIN_ID="${L2_CHAIN_ID:-78651}"
L2_VERIFIER_URL="${L2_VERIFIER_URL:-https://explorer-nilav-shzvox09l5.t.conduit.xyz/api/}"

L1_CHAIN="${L1_CHAIN:-sepolia}"
L1_VERIFIER="${L1_VERIFIER:-etherscan}"
L1_VERIFIER_URL="${L1_VERIFIER_URL:-}"
SOLC_VERSION="${SOLC_VERSION:-0.8.26}"
SOLC_PATH="${SOLC_PATH:-$REPO_ROOT/tools/solc-$SOLC_VERSION}"
ETHERSCAN_API_VERSION="${ETHERSCAN_API_VERSION:-v2}"
ETHERSCAN_VERIFIER_URL="${ETHERSCAN_VERIFIER_URL:-https://api.etherscan.io/v2/api}"

TOKEN_NAME="${TOKEN_NAME:-Nillion}"
TOKEN_SYMBOL="${TOKEN_SYMBOL:-NIL}"
TOKEN_DECIMALS="${TOKEN_DECIMALS:-6}"

EPOCH_START="${EPOCH_START-}"
if [[ -z "$EPOCH_START" ]]; then
if [[ -n "${FORCE_EPOCH_START-}" ]]; then
  EPOCH_START="$FORCE_EPOCH_START"
else
  EPOCH_START="$(date +%s)"
fi
fi
EPOCH_DURATION="${EPOCH_DURATION:-604800}"
L2_GAS_LIMIT="${L2_GAS_LIMIT:-200000}"
GLOBAL_MINT_CAP="${GLOBAL_MINT_CAP:-0}"
REWARD_EPOCH_DURATION="${REWARD_EPOCH_DURATION:-$EPOCH_DURATION}"

EMISSIONS_WEEKLY_UNITS="${EMISSIONS_WEEKLY_UNITS:-96153846153}"
EMISSIONS_WEEKS="${EMISSIONS_WEEKS:-520}"
EMISSIONS_SCHEDULE="${EMISSIONS_SCHEDULE:-}"
ROUND_INTERVAL_MINUTES="${ROUND_INTERVAL_MINUTES:-10}"
REWARD_PAYOUT_CUSHION_BPS="${REWARD_PAYOUT_CUSHION_BPS:-12000}"
REWARD_MAX_PAYOUT_PER_FINALIZE="${REWARD_MAX_PAYOUT_PER_FINALIZE-}"
USE_NOOP_SLASHING="${USE_NOOP_SLASHING:-true}"

if [[ -z "$EMISSIONS_SCHEDULE" ]]; then
  EMISSIONS_SCHEDULE="$(python3 - <<PY
weekly = int("${EMISSIONS_WEEKLY_UNITS}")
weeks = int("${EMISSIONS_WEEKS}")
print(",".join([str(weekly)] * weeks))
PY
)"
fi

if [[ -z "$REWARD_MAX_PAYOUT_PER_FINALIZE" ]]; then
  REWARD_MAX_PAYOUT_PER_FINALIZE="$(python3 - <<PY
import math
weekly = int("${EMISSIONS_WEEKLY_UNITS}")
interval = int("${ROUND_INTERVAL_MINUTES}")
if interval <= 0:
    raise SystemExit("ROUND_INTERVAL_MINUTES must be > 0")
rounds = (7 * 24 * 60) / interval
per_round = weekly / rounds
cushion_bps = int("${REWARD_PAYOUT_CUSHION_BPS}")
cap = math.ceil(per_round * cushion_bps / 10000)
print(cap)
PY
)"
fi

DEPLOYER="$(cast wallet address --private-key "$PRIVATE_KEY")"

BROADCAST_ARGS=(--broadcast)
if [[ "$DRY_RUN" == "1" ]]; then
  BROADCAST_ARGS=()
  SKIP_VERIFY=1
  SKIP_SET_MINTER=1
  STATE_FILE="${STATE_FILE%.env}.dry-run.env"
fi

assert_chain_id "$L1_RPC_URL" "${EXPECTED_L1_CHAIN_ID:-}"
assert_chain_id "$L2_RPC_URL" "${EXPECTED_L2_CHAIN_ID:-}"

if ! address_has_code "$L1_RPC_URL" "$L1_BRIDGE"; then
  echo "L1_BRIDGE has no bytecode at $L1_BRIDGE" >&2
  exit 1
fi

if [[ -n "${L1_NIL_ADDRESS:-}" ]] && ! address_has_code "$L1_RPC_URL" "$L1_NIL_ADDRESS"; then
  echo "Provided L1_NIL_ADDRESS has no bytecode: $L1_NIL_ADDRESS" >&2
  exit 1
fi

extract_deployed_address() {
  local log="$1"
  local line
  local addr
  if command -v rg >/dev/null 2>&1; then
    line="$(rg -m 1 "Deployed to:" "$log" || true)"
  else
    line="$(grep -E "Deployed to:" "$log" | head -n 1 || true)"
  fi

  if [[ -n "$line" ]]; then
    addr="$(echo "$line" | awk '{print $3}')"
    if [[ -n "$addr" ]]; then
      echo "$addr"
      return
    fi
  fi

  if command -v rg >/dev/null 2>&1; then
    rg -o "0x[a-fA-F0-9]{40}" "$log" | head -n 1
  else
    grep -Eo "0x[a-fA-F0-9]{40}" "$log" | head -n 1
  fi
}

extract_label_address() {
  local label="$1"
  local log="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -m 1 "^[[:space:]]*${label}:" "$log" | awk -F': ' '{print $2}'
  else
    grep -E "^[[:space:]]*${label}:" "$log" | head -n 1 | awk -F': ' '{print $2}'
  fi
}

if [[ -z "${L1_NIL_ADDRESS:-}" && "${SKIP_DEPLOY_L1_NIL:-0}" != "1" ]]; then
  echo "Deploying L1 NIL token..."
  L1_TOKEN_LOG="$LOG_DIR/l1_nil.log"
  (
    cd "$REPO_ROOT"
    forge create src/NillionToken.sol:NillionToken \
      --rpc-url "$L1_RPC_URL" \
      --private-key "$PRIVATE_KEY" \
      "${BROADCAST_ARGS[@]+"${BROADCAST_ARGS[@]}"}" \
      --constructor-args "$DEPLOYER" 2>&1 | tee "$L1_TOKEN_LOG"
  ) >/dev/null
  L1_NIL_ADDRESS="$(extract_deployed_address "$L1_TOKEN_LOG")"
else
  require_env L1_NIL_ADDRESS
  echo "Using existing L1 NIL: $L1_NIL_ADDRESS"
fi

if [[ -z "${L2_NIL_ADDRESS:-}" && "${SKIP_DEPLOY_L2_NIL:-0}" != "1" ]]; then
  echo "Deploying L2 NIL token (OptimismMintableERC20)..."
  L2_TOKEN_LOG="$LOG_DIR/l2_nil.log"
  (
    cd "$REPO_ROOT"
    forge create src/OptimismMintableERC20.sol:OptimismMintableERC20 \
      --rpc-url "$L2_RPC_URL" \
      --private-key "$PRIVATE_KEY" \
      "${BROADCAST_ARGS[@]+"${BROADCAST_ARGS[@]}"}" \
      --constructor-args "$L2_BRIDGE" "$L1_NIL_ADDRESS" "$TOKEN_NAME" "$TOKEN_SYMBOL" "$TOKEN_DECIMALS" 2>&1 | tee "$L2_TOKEN_LOG"
  ) >/dev/null
  L2_NIL_ADDRESS="$(extract_deployed_address "$L2_TOKEN_LOG")"
else
  require_env L2_NIL_ADDRESS
  echo "Using existing L2 NIL: $L2_NIL_ADDRESS"
fi

if [[ "${SKIP_DEPLOY_L2_SUITE:-0}" != "1" ]]; then
  echo "Deploying L2 contract suite..."
  L2_SUITE_LOG="$LOG_DIR/l2_suite.log"
  (
    cd "$REPO_ROOT"
    USE_MOCK_TOKENS=false \
      STAKE_TOKEN="$L2_NIL_ADDRESS" \
      REWARD_TOKEN="$L2_NIL_ADDRESS" \
      GOVERNANCE="$DEPLOYER" \
      ADMIN="$DEPLOYER" \
      USE_NOOP_SLASHING="$USE_NOOP_SLASHING" \
      HEARTBEAT_SUBMITTERS="${HEARTBEAT_SUBMITTERS:-}" \
      REWARD_EPOCH_DURATION="$REWARD_EPOCH_DURATION" \
      REWARD_MAX_PAYOUT_PER_FINALIZE="$REWARD_MAX_PAYOUT_PER_FINALIZE" \
      forge script script/deployment/DeployTestRCSystem.s.sol:DeployTestRCSystem \
      --rpc-url "$L2_RPC_URL" "${BROADCAST_ARGS[@]+"${BROADCAST_ARGS[@]}"}" 2>&1 | tee "$L2_SUITE_LOG"
  ) >/dev/null

  STAKING_ADDRESS="$(extract_label_address "StakingOperators" "$L2_SUITE_LOG")"
  SELECTOR_ADDRESS="$(extract_label_address "WeightedCommitteeSelector" "$L2_SUITE_LOG")"
  CONFIG_ADDRESS="$(extract_label_address "ProtocolConfig" "$L2_SUITE_LOG")"
  MANAGER_ADDRESS="$(extract_label_address "HeartbeatManager" "$L2_SUITE_LOG")"
  REWARD_ADDRESS="$(extract_label_address "RewardPolicy" "$L2_SUITE_LOG")"
  JAIL_ADDRESS="$(extract_label_address "JailingPolicy" "$L2_SUITE_LOG" || true)"
  SLASHING_ADDRESS="$(extract_label_address "NoOpSlashingPolicy" "$L2_SUITE_LOG")"
  if [[ -z "$SLASHING_ADDRESS" ]]; then
    SLASHING_ADDRESS="$JAIL_ADDRESS"
  fi
else
  require_env STAKING_ADDRESS
  require_env SELECTOR_ADDRESS
  require_env CONFIG_ADDRESS
  require_env MANAGER_ADDRESS
  require_env REWARD_ADDRESS
  if [[ -z "${SLASHING_ADDRESS:-}" && -n "${JAIL_ADDRESS:-}" ]]; then
    SLASHING_ADDRESS="$JAIL_ADDRESS"
  fi
  require_env SLASHING_ADDRESS
  if [[ "${USE_NOOP_SLASHING}" != "true" ]]; then
    require_env JAIL_ADDRESS
  fi
  echo "Using existing L2 suite addresses."
fi

assert_contract_interface "$L2_RPC_URL" "$STAKING_ADDRESS" "stakingToken()(address)"
assert_contract_interface "$L2_RPC_URL" "$MANAGER_ADDRESS" "nodeCount()(uint256)"
assert_contract_interface "$L2_RPC_URL" "$REWARD_ADDRESS" "spendableBudget()(uint256)"

if [[ "${SKIP_DEPLOY_L1_EMISSIONS:-0}" != "1" ]]; then
  echo "Deploying EmissionsController on L1..."
  L1_EMISSIONS_LOG="$LOG_DIR/l1_emissions.log"
  (
    cd "$REPO_ROOT"
    PRIVATE_KEY="$PRIVATE_KEY" \
      TOKEN="$L1_NIL_ADDRESS" \
      L1_BRIDGE="$L1_BRIDGE" \
      L2_TOKEN="$L2_NIL_ADDRESS" \
      REMAINDER_SINK_ADDR="$REWARD_ADDRESS" \
      REMAINDER_SINK_IS_L2="true" \
      EPOCH_START="$EPOCH_START" \
      EPOCH_DURATION="$EPOCH_DURATION" \
      L2_GAS_LIMIT="$L2_GAS_LIMIT" \
      GLOBAL_MINT_CAP="$GLOBAL_MINT_CAP" \
      EMISSIONS_SCHEDULE="$EMISSIONS_SCHEDULE" \
      forge script script/deployment/DeployEmissionsController.s.sol:DeployEmissionsController \
      --rpc-url "$L1_RPC_URL" "${BROADCAST_ARGS[@]+"${BROADCAST_ARGS[@]}"}" 2>&1 | tee "$L1_EMISSIONS_LOG"
  ) >/dev/null
  L1_EMISSIONS_ADDRESS="$(extract_label_address "EmissionsController" "$L1_EMISSIONS_LOG")"
  echo "EmissionsController: $L1_EMISSIONS_ADDRESS"
else
  require_env L1_EMISSIONS_ADDRESS
  echo "Using existing EmissionsController: $L1_EMISSIONS_ADDRESS"
fi

if [[ "${SKIP_SET_MINTER:-0}" != "1" ]]; then
  echo "Authorizing EmissionsController as L1 NIL minter..."
  cast send --rpc-url "$L1_RPC_URL" --private-key "$PRIVATE_KEY" \
    "$L1_NIL_ADDRESS" "setMinter(address,bool)" "$L1_EMISSIONS_ADDRESS" true >/dev/null
fi

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
  ensure_solc
  echo "Verifying L2 NIL (blockscout)..."
(
  cd "$REPO_ROOT"
  FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" forge verify-contract \
    --rpc-url "$L2_RPC_URL" \
    --chain "$L2_CHAIN_ID" \
    --verifier blockscout \
    --verifier-url "$L2_VERIFIER_URL" \
    "$L2_NIL_ADDRESS" \
    src/OptimismMintableERC20.sol:OptimismMintableERC20 \
    --compiler-version "$SOLC_VERSION" \
    --constructor-args "$(cast abi-encode 'constructor(address,address,string,string,uint8)' \
      "$L2_BRIDGE" "$L1_NIL_ADDRESS" "$TOKEN_NAME" "$TOKEN_SYMBOL" "$TOKEN_DECIMALS")"
)

  echo "Verifying L2 suite (blockscout)..."
(
  cd "$REPO_ROOT"
  FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" forge verify-contract \
    --rpc-url "$L2_RPC_URL" \
    --chain "$L2_CHAIN_ID" \
    --verifier blockscout \
    --verifier-url "$L2_VERIFIER_URL" \
    "$STAKING_ADDRESS" \
    src/StakingOperators.sol:StakingOperators \
    --compiler-version "$SOLC_VERSION" \
    --constructor-args "$(cast abi-encode 'constructor(address,address,uint256)' \
      "$L2_NIL_ADDRESS" "$DEPLOYER" 86400)"

  FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" forge verify-contract \
    --rpc-url "$L2_RPC_URL" \
    --chain "$L2_CHAIN_ID" \
    --verifier blockscout \
    --verifier-url "$L2_VERIFIER_URL" \
    "$SELECTOR_ADDRESS" \
    src/WeightedCommitteeSelector.sol:WeightedCommitteeSelector \
    --compiler-version "$SOLC_VERSION" \
    --constructor-args "$(cast abi-encode 'constructor(address,address,uint256,uint32)' \
      "$STAKING_ADDRESS" "$DEPLOYER" 1 200)"

  FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" forge verify-contract \
    --rpc-url "$L2_RPC_URL" \
    --chain "$L2_CHAIN_ID" \
    --verifier blockscout \
    --verifier-url "$L2_VERIFIER_URL" \
    "$CONFIG_ADDRESS" \
    src/ProtocolConfig.sol:ProtocolConfig \
    --compiler-version "$SOLC_VERSION" \
    --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,address,uint32,uint32,uint32,uint8,uint16,uint16,uint256,uint256,uint256,uint256,uint256,uint16)' \
      "$DEPLOYER" \
      "$STAKING_ADDRESS" \
      "$SELECTOR_ADDRESS" \
      "$STAKING_ADDRESS" \
      "$SELECTOR_ADDRESS" \
      10 0 200 0 9000 7000 300 120 100 10000000 10000000 1000)"

  FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" forge verify-contract \
    --rpc-url "$L2_RPC_URL" \
    --chain "$L2_CHAIN_ID" \
    --verifier blockscout \
    --verifier-url "$L2_VERIFIER_URL" \
    "$MANAGER_ADDRESS" \
    src/HeartbeatManager.sol:HeartbeatManager \
    --compiler-version "$SOLC_VERSION" \
    --constructor-args "$(cast abi-encode 'constructor(address,address)' \
      "$CONFIG_ADDRESS" "$DEPLOYER")"

  FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" forge verify-contract \
    --rpc-url "$L2_RPC_URL" \
    --chain "$L2_CHAIN_ID" \
    --verifier blockscout \
    --verifier-url "$L2_VERIFIER_URL" \
    "$REWARD_ADDRESS" \
    src/RewardPolicy.sol:RewardPolicy \
    --compiler-version "$SOLC_VERSION" \
    --constructor-args "$(cast abi-encode 'constructor(address,address,address,uint256,uint256)' \
      "$L2_NIL_ADDRESS" "$MANAGER_ADDRESS" "$DEPLOYER" "$REWARD_EPOCH_DURATION" "$REWARD_MAX_PAYOUT_PER_FINALIZE")"

  if [[ "${USE_NOOP_SLASHING}" == "true" ]]; then
    FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" forge verify-contract \
      --rpc-url "$L2_RPC_URL" \
      --chain "$L2_CHAIN_ID" \
      --verifier blockscout \
      --verifier-url "$L2_VERIFIER_URL" \
      "$SLASHING_ADDRESS" \
      src/NoOpSlashingPolicy.sol:NoOpSlashingPolicy \
      --compiler-version "$SOLC_VERSION"
  else
    FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" forge verify-contract \
      --rpc-url "$L2_RPC_URL" \
      --chain "$L2_CHAIN_ID" \
      --verifier blockscout \
      --verifier-url "$L2_VERIFIER_URL" \
      "$JAIL_ADDRESS" \
      src/JailingPolicy.sol:JailingPolicy \
      --compiler-version "$SOLC_VERSION" \
      --constructor-args "$(cast abi-encode 'constructor(address)' "$MANAGER_ADDRESS")"
  fi
)

  echo "Verifying L1 NIL + EmissionsController..."
  if [[ "$L1_VERIFIER" == "etherscan" ]]; then
    require_env ETHERSCAN_API_KEY
    (
      cd "$REPO_ROOT"
      FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" ETHERSCAN_API_VERSION="$ETHERSCAN_API_VERSION" forge verify-contract \
        --rpc-url "$L1_RPC_URL" \
        --chain "$L1_CHAIN" \
        --verifier etherscan \
        --verifier-url "$ETHERSCAN_VERIFIER_URL" \
        --etherscan-api-key "$ETHERSCAN_API_KEY" \
        "$L1_NIL_ADDRESS" \
        src/NillionToken.sol:NillionToken \
        --compiler-version "$SOLC_VERSION" \
        --constructor-args "$(cast abi-encode 'constructor(address)' "$DEPLOYER")"

      FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" ETHERSCAN_API_VERSION="$ETHERSCAN_API_VERSION" forge verify-contract \
        --rpc-url "$L1_RPC_URL" \
        --chain "$L1_CHAIN" \
        --verifier etherscan \
        --verifier-url "$ETHERSCAN_VERIFIER_URL" \
        --etherscan-api-key "$ETHERSCAN_API_KEY" \
        "$L1_EMISSIONS_ADDRESS" \
        src/EmissionsController.sol:EmissionsController \
        --compiler-version "$SOLC_VERSION" \
        --guess-constructor-args
    )
  else
    require_env L1_VERIFIER_URL
    (
      cd "$REPO_ROOT"
      FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" forge verify-contract \
        --rpc-url "$L1_RPC_URL" \
        --chain "$L1_CHAIN" \
        --verifier blockscout \
        --verifier-url "$L1_VERIFIER_URL" \
        "$L1_NIL_ADDRESS" \
        src/NillionToken.sol:NillionToken \
        --compiler-version "$SOLC_VERSION" \
        --constructor-args "$(cast abi-encode 'constructor(address)' "$DEPLOYER")"

      FOUNDRY_DISABLE_SOLC_DOWNLOAD=1 FOUNDRY_SOLC_VERSION="$SOLC_VERSION" FOUNDRY_SOLC_PATH="$SOLC_PATH" forge verify-contract \
        --rpc-url "$L1_RPC_URL" \
        --chain "$L1_CHAIN" \
        --verifier blockscout \
        --verifier-url "$L1_VERIFIER_URL" \
        "$L1_EMISSIONS_ADDRESS" \
        src/EmissionsController.sol:EmissionsController \
        --compiler-version "$SOLC_VERSION" \
        --guess-constructor-args
    )
  fi
fi

cat <<EOF
Deployment complete. Addresses:
- L1 NIL: $L1_NIL_ADDRESS
- L2 NIL: $L2_NIL_ADDRESS
- StakingOperators: $STAKING_ADDRESS
- WeightedCommitteeSelector: $SELECTOR_ADDRESS
- ProtocolConfig: $CONFIG_ADDRESS
- HeartbeatManager: $MANAGER_ADDRESS
- RewardPolicy: $REWARD_ADDRESS
- SlashingPolicy: $SLASHING_ADDRESS
- JailingPolicy: ${JAIL_ADDRESS:-}
- EmissionsController: $L1_EMISSIONS_ADDRESS
- Reward epoch duration: $REWARD_EPOCH_DURATION
- Reward max payout per finalize: $REWARD_MAX_PAYOUT_PER_FINALIZE
Logs saved in: $LOG_DIR
EOF

cat > "$STATE_FILE" <<EOF
L1_NIL_ADDRESS=$L1_NIL_ADDRESS
L2_NIL_ADDRESS=$L2_NIL_ADDRESS
STAKING_ADDRESS=$STAKING_ADDRESS
SELECTOR_ADDRESS=$SELECTOR_ADDRESS
CONFIG_ADDRESS=$CONFIG_ADDRESS
MANAGER_ADDRESS=$MANAGER_ADDRESS
REWARD_ADDRESS=$REWARD_ADDRESS
SLASHING_ADDRESS=$SLASHING_ADDRESS
JAIL_ADDRESS=${JAIL_ADDRESS:-}
L1_EMISSIONS_ADDRESS=$L1_EMISSIONS_ADDRESS
EOF

write_env_json_artifact \
  "$STATE_FILE" \
  "$LOG_DIR/addresses.json" \
  "testnet-suite" \
  "$L2_CHAIN_ID" \
  "$([[ "$DRY_RUN" == "1" ]] && echo "dry-run" || echo "broadcast")"
