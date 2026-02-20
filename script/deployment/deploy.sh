#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck source=script/deployment/shlib/common.sh
source "$SCRIPT_DIR/shlib/common.sh"

REPO_ROOT="$(repo_root_from_script "$SCRIPT_PATH")"
cd "$REPO_ROOT"

usage() {
  cat <<'USAGE'
Unified deployment entrypoint.

Usage:
  ./script/deployment/deploy.sh <target> [options]

Targets:
  core          Deploy core Blacklight suite
  erc8004       Deploy ERC-8004 contracts
  node-factory  Deploy NodeOperatorFactory (optionally verify)
  node-managers Deploy NodeOperatorFactory and managed nodes
  full-anvil    Deploy core + ERC-8004 + node managers for local Anvil
  testnet-with-verify Deploy full L1/L2 testnet flow with verification
  mainnet-with-verify Deploy full L1/L2 mainnet flow with verification

Options:
  --profile <path>           Load KEY=VALUE profile file
  --profile-json <path>      Load JSON profile and export top-level keys as env vars
  --config <path>            Typed JSON config file for `core` target
  --rpc-url <url>            Set RPC_URL
  --private-key <hex>        Set PRIVATE_KEY
  --mnemonic <words>         Set MNEMONIC
  --num-operators <n>        Set NUM_OPERATORS
  --expected-chain-id <id>   Fail if RPC chain id mismatches
  --artifact-dir <path>      Where JSON artifacts are written (default: target/deploy-artifacts)
  --set KEY=VALUE            Override any deployment variable (repeatable)
  --dry-run                  Simulate without broadcasting txs
  --resume                   Reuse existing env outputs when addresses already have bytecode (default)
  --no-resume                Always redeploy
  --skip-build               Skip forge build step
  -h, --help                 Show this help
USAGE
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

TARGET="$1"
shift

# Well-known Anvil account 0 key — only used as a local-dev default.
_ANVIL_DEFAULT_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

PROFILE=""
PROFILE_JSON=""
CONFIG_PATH=""
SKIP_BUILD="0"
DRY_RUN="0"
RESUME="1"
ARTIFACT_DIR="target/deploy-artifacts"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
EXPECTED_CHAIN_ID_CLI=""
EXPECTED_CHAIN_ID_FROM_CLI="0"
OVERRIDES=()

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
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --rpc-url)
      export RPC_URL="$2"
      shift 2
      ;;
    --private-key)
      export PRIVATE_KEY="$2"
      shift 2
      ;;
    --mnemonic)
      export MNEMONIC="$2"
      shift 2
      ;;
    --num-operators)
      export NUM_OPERATORS="$2"
      shift 2
      ;;
    --expected-chain-id)
      EXPECTED_CHAIN_ID="$2"
      EXPECTED_CHAIN_ID_CLI="$2"
      EXPECTED_CHAIN_ID_FROM_CLI="1"
      shift 2
      ;;
    --artifact-dir)
      ARTIFACT_DIR="$2"
      shift 2
      ;;
    --set)
      OVERRIDES+=("$2")
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD="1"
      shift
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
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

load_profile_if_present "$PROFILE"
load_json_profile_if_present "$PROFILE_JSON"
if [[ ${#OVERRIDES[@]} -gt 0 ]]; then
  apply_overrides "${OVERRIDES[@]}"
fi
if [[ "$EXPECTED_CHAIN_ID_FROM_CLI" == "1" ]]; then
  # Ensure explicit CLI guard is not overridden by profile values.
  EXPECTED_CHAIN_ID="$EXPECTED_CHAIN_ID_CLI"
  export EXPECTED_CHAIN_ID
fi

require_cmd forge
require_cmd curl
require_cmd cast
require_cmd python3
assert_toolchain

MODE="broadcast"
BROADCAST_ARGS=("--broadcast")
WRITE_OUTPUT="true"
if [[ "$DRY_RUN" == "1" ]]; then
  MODE="dry-run"
  BROADCAST_ARGS=()
  # Avoid persisting simulated addresses from dry-runs into *.env output files.
  WRITE_OUTPUT="false"
fi
export WRITE_OUTPUT

mkdir -p "$ARTIFACT_DIR"

bool_is_true() {
  [[ "${1:-}" == "1" || "${1:-}" == "true" || "${1:-}" == "TRUE" ]]
}

now_utc_stamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

write_plan_artifact() {
  local target="$1"
  local rpc_url="$2"
  local config_path="$3"
  local out="$ARTIFACT_DIR/${target}-plan-$(now_utc_stamp).json"
  python3 - "$out" "$target" "$MODE" "$rpc_url" "$config_path" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
out, target, mode, rpc, config = sys.argv[1:6]
payload = {
  "target": target,
  "mode": mode,
  "rpcUrl": rpc,
  "config": config,
  "generatedAt": datetime.now(timezone.utc).isoformat(),
}
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
  json.dump(payload, f, indent=2)
  f.write("\n")
print(f"Plan artifact: {out}")
PY
}

build_if_needed() {
  if [[ "$SKIP_BUILD" == "1" ]]; then
    return
  fi
  forge build
}

write_target_artifact_if_possible() {
  local target="$1"
  local rpc_url="$2"
  local env_file="$3"
  if [[ ! -f "$env_file" ]]; then
    return
  fi
  local cid out
  cid="$(cast chain-id --rpc-url "$rpc_url")"
  out="$ARTIFACT_DIR/${target}-chain${cid}-$(now_utc_stamp).json"
  write_env_json_artifact "$env_file" "$out" "$target" "$cid" "$MODE"
  echo "Artifact: $out"
}

build_passthrough_args() {
  PASSTHROUGH_ARGS=()
  if [[ -n "$PROFILE" ]]; then
    PASSTHROUGH_ARGS+=(--profile "$PROFILE")
  fi
  if [[ -n "$PROFILE_JSON" ]]; then
    PASSTHROUGH_ARGS+=(--profile-json "$PROFILE_JSON")
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    PASSTHROUGH_ARGS+=(--dry-run)
  fi
  if [[ "$RESUME" == "1" ]]; then
    PASSTHROUGH_ARGS+=(--resume)
  else
    PASSTHROUGH_ARGS+=(--no-resume)
  fi
  # testnet/mainnet scripts handle two chains; use --set EXPECTED_L1_CHAIN_ID=X
  # and --set EXPECTED_L2_CHAIN_ID=Y to guard individual chains instead.
  local item
  for item in "${OVERRIDES[@]}"; do
    PASSTHROUGH_ARGS+=(--set "$item")
  done
}

deploy_core() {
  local rpc_url private_key expected
  rpc_url="${RPC_URL:-http://127.0.0.1:8545}"
  private_key="${PRIVATE_KEY:-$_ANVIL_DEFAULT_KEY}"
  export RPC_URL="$rpc_url" PRIVATE_KEY="$private_key"

  expected="$EXPECTED_CHAIN_ID"
  if [[ -z "$expected" && "$rpc_url" == "http://127.0.0.1:8545" ]]; then
    expected="31337"
  fi

  check_rpc "$rpc_url"
  assert_chain_id "$rpc_url" "$expected"

  if [[ -z "$CONFIG_PATH" ]]; then
    CONFIG_PATH="script/deployment/configs/core.anvil.json"
  fi
  require_file "$CONFIG_PATH"

  if [[ "$RESUME" == "1" && "$DRY_RUN" == "0" && -f "contract_addresses.env" ]]; then
    if env_file_addresses_have_code "$rpc_url" "contract_addresses.env" \
      STAKE_TOKEN STAKING_OPERATORS WEIGHTED_COMMITTEE_SELECTOR PROTOCOL_CONFIG HEARTBEAT_MANAGER REWARD_POLICY SLASHING_POLICY; then
      echo "Reusing existing core deployment from contract_addresses.env"
      print_kv_file "contract_addresses.env"
      write_target_artifact_if_possible "core" "$rpc_url" "contract_addresses.env"
      return
    fi
    echo "Existing contract_addresses.env is stale; redeploying core."
  fi

  build_if_needed
  if [[ "$DRY_RUN" == "1" ]]; then
    write_plan_artifact "core" "$rpc_url" "$CONFIG_PATH"
  fi

  forge script script/deployment/DeployBlacklightFromConfig.s.sol:DeployBlacklightFromConfig \
    --sig "run(string)" "$CONFIG_PATH" \
    --rpc-url "$rpc_url" \
    "${BROADCAST_ARGS[@]+"${BROADCAST_ARGS[@]}"}"

  if [[ "$DRY_RUN" == "0" ]]; then
    print_kv_file "contract_addresses.env"
    write_target_artifact_if_possible "core" "$rpc_url" "contract_addresses.env"
  fi
}

deploy_erc8004() {
  local rpc_url private_key expected reputation
  rpc_url="${RPC_URL:-http://127.0.0.1:8545}"
  private_key="${PRIVATE_KEY:-$_ANVIL_DEFAULT_KEY}"
  export RPC_URL="$rpc_url" PRIVATE_KEY="$private_key"

  expected="$EXPECTED_CHAIN_ID"
  if [[ -z "$expected" && "$rpc_url" == "http://127.0.0.1:8545" ]]; then
    expected="31337"
  fi

  check_rpc "$rpc_url"
  assert_chain_id "$rpc_url" "$expected"

  if [[ "$DRY_RUN" == "0" && -n "${HEARTBEAT_MANAGER:-}" && "${HEARTBEAT_MANAGER}" != "0x0000000000000000000000000000000000000000" ]]; then
    if ! address_has_code "$rpc_url" "$HEARTBEAT_MANAGER"; then
      echo "HEARTBEAT_MANAGER has no code: $HEARTBEAT_MANAGER" >&2
      exit 1
    fi
    assert_contract_interface "$rpc_url" "$HEARTBEAT_MANAGER" "HEARTBEAT_SUBMITTER_ROLE()(bytes32)"
  fi

  reputation="${DEPLOY_REPUTATION:-true}"
  if [[ "$RESUME" == "1" && "$DRY_RUN" == "0" && -f "erc8004_addresses.env" ]]; then
    if bool_is_true "$reputation"; then
      if env_file_addresses_have_code "$rpc_url" "erc8004_addresses.env" \
        MINIMAL_UUPS_IMPL IDENTITY_REGISTRY_IMPL IDENTITY_REGISTRY VALIDATION_REGISTRY_IMPL VALIDATION_REGISTRY REPUTATION_REGISTRY_IMPL REPUTATION_REGISTRY; then
        echo "Reusing existing ERC-8004 deployment from erc8004_addresses.env"
        print_kv_file "erc8004_addresses.env"
        write_target_artifact_if_possible "erc8004" "$rpc_url" "erc8004_addresses.env"
        return
      fi
    else
      if env_file_addresses_have_code "$rpc_url" "erc8004_addresses.env" \
        MINIMAL_UUPS_IMPL IDENTITY_REGISTRY_IMPL IDENTITY_REGISTRY VALIDATION_REGISTRY_IMPL VALIDATION_REGISTRY; then
        echo "Reusing existing ERC-8004 deployment from erc8004_addresses.env"
        print_kv_file "erc8004_addresses.env"
        write_target_artifact_if_possible "erc8004" "$rpc_url" "erc8004_addresses.env"
        return
      fi
    fi
    echo "Existing erc8004_addresses.env is stale; redeploying ERC-8004 suite."
  fi

  build_if_needed
  if [[ "$DRY_RUN" == "1" ]]; then
    write_plan_artifact "erc8004" "$rpc_url" ""
  fi

  forge script script/deployment/DeployERC8004.s.sol:DeployERC8004 \
    --rpc-url "$rpc_url" \
    "${BROADCAST_ARGS[@]+"${BROADCAST_ARGS[@]}"}"

  if [[ "$DRY_RUN" == "0" ]]; then
    print_kv_file "erc8004_addresses.env"
    write_target_artifact_if_possible "erc8004" "$rpc_url" "erc8004_addresses.env"
  fi
}

deploy_node_managers() {
  local rpc_url private_key expected
  rpc_url="${RPC_URL:-http://127.0.0.1:8545}"
  private_key="${PRIVATE_KEY:-$_ANVIL_DEFAULT_KEY}"
  export RPC_URL="$rpc_url" PRIVATE_KEY="$private_key"

  expected="$EXPECTED_CHAIN_ID"
  if [[ -z "$expected" && "$rpc_url" == "http://127.0.0.1:8545" ]]; then
    expected="31337"
  fi

  require_env STAKE_TOKEN
  require_env MNEMONIC
  require_env NUM_OPERATORS

  DEPLOY_NODE_FACTORY="${DEPLOY_NODE_FACTORY:-true}"
  export DEPLOY_NODE_FACTORY

  check_rpc "$rpc_url"
  assert_chain_id "$rpc_url" "$expected"

  if [[ "$DRY_RUN" == "0" ]]; then
    if ! address_has_code "$rpc_url" "$STAKE_TOKEN"; then
      echo "STAKE_TOKEN has no bytecode: $STAKE_TOKEN" >&2
      exit 1
    fi
    assert_contract_interface "$rpc_url" "$STAKE_TOKEN" "decimals()(uint8)"
  fi

  if bool_is_true "$DEPLOY_NODE_FACTORY"; then
    require_env STAKING_OPERATORS
    require_env REWARD_POLICY

    if [[ "$DRY_RUN" == "0" ]]; then
      if ! address_has_code "$rpc_url" "$STAKING_OPERATORS"; then
        echo "STAKING_OPERATORS has no bytecode: $STAKING_OPERATORS" >&2
        exit 1
      fi
      if ! address_has_code "$rpc_url" "$REWARD_POLICY"; then
        echo "REWARD_POLICY has no bytecode: $REWARD_POLICY" >&2
        exit 1
      fi

      assert_contract_interface "$rpc_url" "$STAKING_OPERATORS" "stakingToken()(address)"
      assert_contract_interface "$rpc_url" "$REWARD_POLICY" "spendableBudget()(uint256)"
    fi
  fi

  if [[ "$RESUME" == "1" && "$DRY_RUN" == "0" && -f "nodemanager_addresses.env" ]]; then
    local factory
    factory="$(env_value_from_file nodemanager_addresses.env NODE_OPERATOR_FACTORY || true)"
    if [[ -n "$factory" ]] && address_has_code "$rpc_url" "$factory"; then
      echo "Reusing existing node manager deployment from nodemanager_addresses.env"
      print_kv_file "nodemanager_addresses.env"
      write_target_artifact_if_possible "node-managers" "$rpc_url" "nodemanager_addresses.env"
      return
    fi
    echo "Existing nodemanager_addresses.env is stale; redeploying node managers."
  fi

  build_if_needed
  if [[ "$DRY_RUN" == "1" ]]; then
    write_plan_artifact "node-managers" "$rpc_url" ""
  fi

  forge script script/deployment/DeployNodeManagers.s.sol:DeployNodeManagers \
    --rpc-url "$rpc_url" \
    "${BROADCAST_ARGS[@]+"${BROADCAST_ARGS[@]}"}"

  if [[ "$DRY_RUN" == "0" ]]; then
    print_kv_file "nodemanager_addresses.env"
    write_target_artifact_if_possible "node-managers" "$rpc_url" "nodemanager_addresses.env"
  fi
}

deploy_node_factory() {
  local rpc_url private_key expected deploy_log factory_address chain_id verifier_url compiler_version deployer
  local out_file
  rpc_url="${RPC_URL:-http://127.0.0.1:8545}"
  private_key="${PRIVATE_KEY:-$_ANVIL_DEFAULT_KEY}"
  export RPC_URL="$rpc_url" PRIVATE_KEY="$private_key"

  expected="$EXPECTED_CHAIN_ID"
  if [[ -z "$expected" && "$rpc_url" == "http://127.0.0.1:8545" ]]; then
    expected="31337"
  fi

  require_env STAKING_OPERATORS
  require_env REWARD_POLICY
  require_env STAKE_TOKEN

  check_rpc "$rpc_url"
  assert_chain_id "$rpc_url" "$expected"

  if ! address_has_code "$rpc_url" "$STAKING_OPERATORS"; then
    echo "STAKING_OPERATORS has no bytecode: $STAKING_OPERATORS" >&2
    exit 1
  fi
  if ! address_has_code "$rpc_url" "$REWARD_POLICY"; then
    echo "REWARD_POLICY has no bytecode: $REWARD_POLICY" >&2
    exit 1
  fi
  if ! address_has_code "$rpc_url" "$STAKE_TOKEN"; then
    echo "STAKE_TOKEN has no bytecode: $STAKE_TOKEN" >&2
    exit 1
  fi

  assert_contract_interface "$rpc_url" "$STAKING_OPERATORS" "stakingToken()(address)"
  assert_contract_interface "$rpc_url" "$REWARD_POLICY" "spendableBudget()(uint256)"
  assert_contract_interface "$rpc_url" "$STAKE_TOKEN" "decimals()(uint8)"

  out_file="node_factory.env"
  if [[ "$RESUME" == "1" && "$DRY_RUN" == "0" && -f "$out_file" ]]; then
    factory_address="$(env_value_from_file "$out_file" NODE_OPERATOR_FACTORY || true)"
    if [[ -n "$factory_address" ]] && address_has_code "$rpc_url" "$factory_address"; then
      echo "Reusing existing node factory deployment from $out_file"
      print_kv_file "$out_file"
      write_target_artifact_if_possible "node-factory" "$rpc_url" "$out_file"
      return
    fi
    echo "Existing $out_file is stale; redeploying node factory."
  fi

  build_if_needed
  if [[ "$DRY_RUN" == "1" ]]; then
    write_plan_artifact "node-factory" "$rpc_url" ""
  fi

  deploy_log="$(mktemp /tmp/deploy_node_factory.XXXXXX)"
  trap 'rm -f "$deploy_log"' RETURN

  forge script script/deployment/DeployNodeOperatorFactory.s.sol:DeployNodeOperatorFactory \
    --rpc-url "$rpc_url" \
    "${BROADCAST_ARGS[@]+"${BROADCAST_ARGS[@]}"}" 2>&1 | tee "$deploy_log"

  factory_address="$(grep "NodeOperatorFactory:" "$deploy_log" | awk '{print $NF}' | head -n 1)"
  if [[ -z "$factory_address" ]]; then
    echo "Failed to extract NodeOperatorFactory address from deploy output" >&2
    exit 1
  fi

  echo "NODE_OPERATOR_FACTORY=$factory_address"

  if [[ "$DRY_RUN" == "1" ]]; then
    return
  fi

  printf "NODE_OPERATOR_FACTORY=%s\n" "$factory_address" > "$out_file"
  write_target_artifact_if_possible "node-factory" "$rpc_url" "$out_file"

  if [[ "${SKIP_VERIFY:-0}" == "1" ]]; then
    echo "Skipping verification (SKIP_VERIFY=1)"
    return
  fi

  deployer="$(cast wallet address --private-key "$private_key")"
  chain_id="${L2_CHAIN_ID:-$(cast chain-id --rpc-url "$rpc_url")}"
  verifier_url="${L2_VERIFIER_URL:-https://explorer.testnet.nillion.network/api/v2/}"
  compiler_version="$(toolchain_solc_version)"
  if [[ -z "$compiler_version" ]]; then
    compiler_version="0.8.26"
  fi

  forge verify-contract \
    --rpc-url "$rpc_url" \
    --chain "$chain_id" \
    --verifier blockscout \
    --verifier-url "$verifier_url" \
    --compiler-version "$compiler_version" \
    --via-ir \
    --constructor-args "$(cast abi-encode 'constructor(address)' "$deployer")" \
    "$factory_address" \
    src/NodeOperatorFactory.sol:NodeOperatorFactory
}

deploy_full_anvil() {
  RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
  PRIVATE_KEY="${PRIVATE_KEY:-$_ANVIL_DEFAULT_KEY}"
  MNEMONIC="${MNEMONIC:-test test test test test test test test test test test junk}"
  NUM_OPERATORS="${NUM_OPERATORS:-10}"
  EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-31337}"
  export RPC_URL PRIVATE_KEY MNEMONIC NUM_OPERATORS EXPECTED_CHAIN_ID

  if [[ -z "$CONFIG_PATH" ]]; then
    CONFIG_PATH="script/deployment/configs/core.anvil.json"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    deploy_core
    write_plan_artifact "erc8004" "$RPC_URL" ""
    write_plan_artifact "node-managers" "$RPC_URL" ""
    echo "Dry-run note: skipped chained erc8004/node-managers execution in full-anvil mode."
    echo "Reason: core dry-run addresses are simulated and not deployed on-chain."
    return
  fi

  deploy_core

  set -a
  # shellcheck disable=SC1091
  source contract_addresses.env
  set +a

  HEARTBEAT_MANAGER="${HEARTBEAT_MANAGER:-}"
  export HEARTBEAT_MANAGER
  deploy_erc8004

  STAKE_TOKEN="${STAKE_TOKEN:-}"
  STAKING_OPERATORS="${STAKING_OPERATORS:-}"
  REWARD_POLICY="${REWARD_POLICY:-}"
  DEPLOY_NODE_FACTORY="${DEPLOY_NODE_FACTORY:-true}"
  NUM_MANAGED_NODES="${NUM_MANAGED_NODES:-0}"
  export STAKE_TOKEN STAKING_OPERATORS REWARD_POLICY DEPLOY_NODE_FACTORY NUM_MANAGED_NODES

  deploy_node_managers
}

deploy_testnet_with_verify() {
  build_passthrough_args
  exec "$SCRIPT_DIR/deploy_testnet_with_verify.sh" "${PASSTHROUGH_ARGS[@]}"
}

deploy_mainnet_with_verify() {
  build_passthrough_args
  exec "$SCRIPT_DIR/deploy_mainnet_with_verify.sh" "${PASSTHROUGH_ARGS[@]}"
}

case "$TARGET" in
  core)
    deploy_core
    ;;
  erc8004)
    deploy_erc8004
    ;;
  node-factory)
    deploy_node_factory
    ;;
  node-managers)
    deploy_node_managers
    ;;
  full-anvil)
    deploy_full_anvil
    ;;
  testnet-with-verify)
    deploy_testnet_with_verify
    ;;
  mainnet-with-verify)
    deploy_mainnet_with_verify
    ;;
  *)
    echo "Unknown target: $TARGET" >&2
    usage
    exit 1
    ;;
esac
