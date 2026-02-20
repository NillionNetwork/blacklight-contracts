#!/usr/bin/env bash

# Shared helpers for deployment shell scripts.

repo_root_from_script() {
  local script_path="$1"
  local script_dir
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"
  cd "$script_dir/../.." && pwd
}

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

check_rpc() {
  local rpc_url="$1"
  if ! curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$rpc_url" >/dev/null 2>&1; then
    echo "RPC endpoint is not available at $rpc_url" >&2
    exit 1
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing required file: $1" >&2
    exit 1
  fi
}

toolchain_solc_version() {
  awk -F'"' '/^\s*solc_version\s*=/{print $2; exit}' foundry.toml
}

toolchain_foundry_version() {
  if [[ ! -f ".tool-versions" ]]; then
    return 0
  fi
  awk '/^foundry /{print $2; exit}' .tool-versions
}

installed_foundry_version() {
  forge --version | awk '/^forge Version:/{print $3; exit}'
}

assert_toolchain() {
  local expected_foundry expected_solc installed
  expected_foundry="$(toolchain_foundry_version || true)"
  expected_solc="$(toolchain_solc_version || true)"
  installed="$(installed_foundry_version)"

  if [[ -n "$expected_foundry" && "$installed" != "$expected_foundry" ]]; then
    echo "Foundry version mismatch: expected $expected_foundry, installed $installed" >&2
    echo "Set ALLOW_UNPINNED_FORGE=1 to bypass temporarily." >&2
    if [[ "${ALLOW_UNPINNED_FORGE:-0}" != "1" ]]; then
      exit 1
    fi
  fi

  if [[ -n "${SOLC_VERSION:-}" && -n "$expected_solc" && "${SOLC_VERSION}" != "$expected_solc" ]]; then
    echo "SOLC_VERSION mismatch: expected $expected_solc from foundry.toml, got ${SOLC_VERSION}" >&2
    exit 1
  fi
}

assert_chain_id() {
  local rpc_url="$1"
  local expected="$2"
  if [[ -z "$expected" ]]; then
    return
  fi
  local actual
  actual="$(cast chain-id --rpc-url "$rpc_url")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Chain ID mismatch for $rpc_url: expected $expected, got $actual" >&2
    exit 1
  fi
}

load_profile_if_present() {
  local profile_file="$1"
  if [[ -z "$profile_file" ]]; then
    return
  fi

  if [[ ! -f "$profile_file" ]]; then
    echo "Profile file not found: $profile_file" >&2
    exit 1
  fi

  local line key raw expanded
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      raw="${BASH_REMATCH[2]}"

      # Trim surrounding whitespace from value.
      raw="${raw#"${raw%%[![:space:]]*}"}"
      raw="${raw%"${raw##*[![:space:]]}"}"

      # Strip optional wrapping quotes.
      if [[ "$raw" =~ ^\"(.*)\"$ ]]; then
        raw="${BASH_REMATCH[1]}"
      elif [[ "$raw" =~ ^\'(.*)\'$ ]]; then
        raw="${BASH_REMATCH[1]}"
      fi

      # Expand $VAR / ${VAR} references safely without eval.
      # string.Template.safe_substitute leaves unrecognised patterns and $()
      # untouched, so this cannot execute arbitrary shell commands.
      expanded="$(python3 -c "
import os, string, sys
print(string.Template(sys.argv[1]).safe_substitute(os.environ), end='')
" "$raw")"

      export "$key=$expanded"
    else
      echo "Invalid profile line (expected KEY=VALUE): $line" >&2
      exit 1
    fi
  done <"$profile_file"
}

load_json_profile_if_present() {
  local json_file="$1"
  if [[ -z "$json_file" ]]; then
    return
  fi
  if [[ ! -f "$json_file" ]]; then
    echo "JSON profile file not found: $json_file" >&2
    exit 1
  fi
  require_cmd python3
  # shellcheck disable=SC1090
  source <(
    python3 - "$json_file" <<'PY'
import json
import shlex
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

for key, value in data.items():
    if value is None:
        continue
    if isinstance(value, bool):
        text = "true" if value else "false"
    elif isinstance(value, list):
        text = ",".join("true" if v is True else "false" if v is False else str(v) for v in value)
    else:
        text = str(value)
    print(f"export {key}={shlex.quote(text)}")
PY
  )
}

apply_overrides() {
  local pair key value
  for pair in "$@"; do
    if [[ "$pair" != *=* ]]; then
      echo "Invalid --set value '$pair' (expected KEY=VALUE)" >&2
      exit 1
    fi
    key="${pair%%=*}"
    value="${pair#*=}"
    if [[ -z "$key" ]]; then
      echo "Invalid --set value '$pair' (empty KEY)" >&2
      exit 1
    fi
    export "$key=$value"
  done
}

print_kv_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "Expected output file not found: $file" >&2
    exit 1
  fi
  grep -v '^#' "$file" | grep '=' || true
}

env_value_from_file() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '
    $1==k {
      v=$2
      gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", v)
      print v
      exit
    }
  ' "$file"
}

address_has_code() {
  local rpc_url="$1"
  local address="$2"
  local code
  code="$(cast code --rpc-url "$rpc_url" "$address" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "0x" && "$code" != "0x0" ]]
}

env_file_addresses_have_code() {
  local rpc_url="$1"
  local file="$2"
  shift 2
  local key value
  for key in "$@"; do
    value="$(env_value_from_file "$file" "$key")"
    if [[ -z "$value" ]]; then
      echo "Missing key '$key' in $file" >&2
      return 1
    fi
    if ! address_has_code "$rpc_url" "$value"; then
      echo "No code at $key=$value on $rpc_url" >&2
      return 1
    fi
  done
  return 0
}

assert_contract_interface() {
  local rpc_url="$1"
  local address="$2"
  local signature="$3"
  if ! cast call --rpc-url "$rpc_url" "$address" "$signature" >/dev/null 2>&1; then
    echo "Interface check failed at $address for signature $signature" >&2
    exit 1
  fi
}

write_env_json_artifact() {
  local env_file="$1"
  local out_json="$2"
  local target="$3"
  local chain_id="$4"
  local mode="$5"
  require_cmd python3
  python3 - "$env_file" "$out_json" "$target" "$chain_id" "$mode" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

env_file, out_json, target, chain_id, mode = sys.argv[1:6]
data = {}
with open(env_file, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k] = v

payload = {
    "target": target,
    "chainId": int(chain_id) if chain_id.isdigit() else chain_id,
    "mode": mode,
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "addresses": data,
}
dirname = os.path.dirname(out_json)
if dirname:
    os.makedirs(dirname, exist_ok=True)
with open(out_json, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}
