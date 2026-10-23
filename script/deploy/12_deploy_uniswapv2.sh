#!/usr/bin/env bash
set -euo pipefail

# 步骤二（UniswapV2 模块）：部署 Factory 与 Router02，地址写入 addresses.uniswapv2.params。
# 自包含——自行加载并校验部署所需文件，不依赖调用方预载环境。
# WETH 地址取自 WETH 模块写出的 addresses.weth.params（先跑 11_deploy_weth.sh）。
# 用法：script/deploy/12_deploy_uniswapv2.sh <network>

network="${1:?usage: script/deploy/12_deploy_uniswapv2.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$DEX_ROOT/script/network/$network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params addresses.weth.params .account; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config (run 11_deploy_weth.sh first)"
        exit 1
    fi
done

env_password="${KEYSTORE_PASSWORD:-}"
set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/addresses.weth.params"
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

# 密码经临时文件传给 forge：--password 会把明文放进进程参数（/proc/<pid>/cmdline 权限 0444，
# 本机所有用户可读）。trap 在写入密码之前安装，chmod/printf 失败也不会留下明文。
PASSWORD_FILE=$(mktemp)
trap 'rm -f "$PASSWORD_FILE"' EXIT
chmod 600 "$PASSWORD_FILE"
printf '%s' "$KEYSTORE_PASSWORD" > "$PASSWORD_FILE"

# WETH 必须是已部署合约：Router 构造参数绑定它，配错会白广播 Factory 与 Router。
weth_code=$(cast code "$WETH_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null) || true
if [[ ! "$weth_code" =~ ^0x[0-9a-fA-F]+$ ]]; then
    echo "Error: WETH_ADDRESS $WETH_ADDRESS is not a deployed contract on chain $CHAIN_ID" >&2
    exit 1
fi

# 地址文件路径相对 DEX_ROOT：forge 以项目根为工作目录执行（vm.writeFile 只允许项目内路径）。
export ADDRESSES_FILE="script/network/$network/addresses.uniswapv2.params"

echo "Network: $network (chain $CHAIN_ID)"
cd "$DEX_ROOT"
echo "Deploying Uniswap V2 Factory and Router02 to $network..."
forge script script/DeployUniswapV2.s.sol:DeployUniswapV2 --sig "run()" \
    --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" \
    --password-file "$PASSWORD_FILE" --broadcast --legacy
# 密码只在本次 forge 调用期间需要，广播结束立即删除。
rm -f "$PASSWORD_FILE"

source "$NETWORK_DIR/addresses.uniswapv2.params"
echo "✓ Factory: $FACTORY_ADDRESS"
echo "✓ Router02: $ROUTER_ADDRESS"
