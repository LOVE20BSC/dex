#!/usr/bin/env bash
set -euo pipefail

# 步骤三（WETH 模块）：本地部署的 WETH 开源验证。自包含——自行载入 network.params、dex.params
# 与 addresses.weth.params。外部 WETH 由对方维护，不在本仓库验证；链不支持时跳过并返回成功。
# 用法：script/deploy/31_verify_weth.sh <network>

network="${1:?usage: script/deploy/31_verify_weth.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$DEX_ROOT/script/network/$network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params dex.params addresses.weth.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

WETH_ADDRESS="" WETH_NAME="" WETH_SYMBOL=""
set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/dex.params"
configured_weth_address="${WETH_ADDRESS:-}"
source "$NETWORK_DIR/addresses.weth.params"
set +a

cd "$DEX_ROOT"

case "$CHAIN_ID" in
    56|97) ;;
    *) echo "Skip: source verification is not configured for chain $CHAIN_ID"; exit 0 ;;
esac

if [ -n "$configured_weth_address" ]; then
    echo "Skip: external WETH is verified by its own deployment, not this repository"
    exit 0
fi

if [ -z "${WETH_NAME:-}" ] || [ -z "${WETH_SYMBOL:-}" ]; then
    echo "Error: local WETH deployment is missing WETH_NAME / WETH_SYMBOL in $NETWORK_DIR/dex.params" >&2
    exit 1
fi
if [[ ! "$WETH_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ "$WETH_ADDRESS" = 0x0000000000000000000000000000000000000000 ]]; then
    echo "Error: Missing or invalid WETH_ADDRESS in $NETWORK_DIR/addresses.weth.params" >&2
    exit 1
fi
: "${ETHERSCAN_API_KEY:?Set an Etherscan API key; source verification has not run.}"

if ! WETH_ARGS=$(cast abi-encode "constructor(string,string)" "$WETH_NAME" "$WETH_SYMBOL"); then
    echo "Error: Failed to encode WETH9Configurable constructor arguments" >&2
    exit 1
fi

forge verify-contract "$WETH_ADDRESS" "script/WETH9Configurable.sol:WETH9Configurable" \
    --chain "$CHAIN_ID" --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api" \
    --constructor-args "$WETH_ARGS" --watch
echo "✓ Source verification succeeded for WETH"
