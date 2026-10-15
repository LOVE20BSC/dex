#!/usr/bin/env bash
set -euo pipefail

# 步骤一（WETH 模块）：就绪 WETH。自包含——自行加载并校验部署所需文件，不依赖调用方预载环境。
# dex.params 配置了 WETH_ADDRESS（公共链的官方 WETH）时校验并使用它；未配置时（本地 anvil）
# 部署上游 WETH9。地址写入 addresses.weth.params，供 UniswapV2 模块与校验步骤载入。
# 用法：script/deploy/11_deploy_weth.sh <network>

network="${1:?usage: script/deploy/11_deploy_weth.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$DEX_ROOT/script/network/$network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params dex.params .account; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

# 清掉可能从调用者环境继承来的取值，避免用别的网络的配置部署。
export WETH_ADDRESS=""

env_password="${KEYSTORE_PASSWORD:-}"
set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/dex.params"
source "$NETWORK_DIR/.account"
set +a

# .account 里的空 KEYSTORE_PASSWORD 行不应清掉入口已导出的密码（避免重复弹窗）。
[ -n "${KEYSTORE_PASSWORD:-}" ] || KEYSTORE_PASSWORD="$env_password"

[ -n "${KEYSTORE_ACCOUNT:-}" ] && [ -n "${ACCOUNT_ADDRESS:-}" ] \
    || { echo "Error: KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS is not set in $NETWORK_DIR/.account" >&2; exit 1; }

# 实际链必须与配置一致；已设 KEYSTORE_PASSWORD 则不弹窗（非交互调用用）。
actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$actual_chain_id" = "$CHAIN_ID" ] || { echo "Error: chain ID mismatch: config=$CHAIN_ID rpc=$actual_chain_id" >&2; exit 1; }
if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
    if ! command -v osascript >/dev/null 2>&1; then
        echo "Error: KEYSTORE_PASSWORD is empty and osascript is unavailable; set it in $NETWORK_DIR/.account for non-interactive use." >&2
        exit 1
    fi
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for $KEYSTORE_ACCOUNT:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
fi

# 配置了 WETH 地址时，它是外部既有合约，广播前必须校验已部署；
# 未配置时由本次部署创建（WETH9），无从预校验，有效性在模拟阶段由 DeployWETH.s.sol 把关。
if [ -n "${WETH_ADDRESS:-}" ]; then
    weth_code=$(cast code "$WETH_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null) || true
    if [[ ! "$weth_code" =~ ^0x[0-9a-fA-F]+$ ]]; then
        echo "Error: WETH_ADDRESS $WETH_ADDRESS is not a deployed contract on chain $CHAIN_ID" >&2
        exit 1
    fi
fi

# 地址文件路径相对 DEX_ROOT：forge 以项目根为工作目录执行（vm.writeFile 只允许项目内路径）。
export ADDRESSES_FILE="script/network/$network/addresses.weth.params"

echo "Network: $network (chain $CHAIN_ID)"
cd "$DEX_ROOT"
echo "Deploying WETH to $network..."
forge script script/DeployWETH.s.sol:DeployWETH --sig "run()" \
    --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" \
    --password "$KEYSTORE_PASSWORD" --broadcast --legacy

source "$NETWORK_DIR/addresses.weth.params"
echo "✓ WETH: $WETH_ADDRESS"
