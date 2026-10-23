#!/usr/bin/env bash
set -euo pipefail

# 步骤一（WETH 模块）：就绪 WETH。自包含——自行加载并校验部署所需文件，不依赖调用方预载环境。
# 参数二选一：
#   WETH_ADDRESS 非空：使用外部已部署 WETH，不部署、不需要 keystore；
#   WETH_ADDRESS 为空：必须提供 WETH_NAME 与 WETH_SYMBOL，部署一个可配置名称/符号的 WETH。
# 地址写入 addresses.weth.params，供 UniswapV2 模块与校验步骤载入。
# 用法：script/deploy/11_deploy_weth.sh <network>

network="${1:?usage: script/deploy/11_deploy_weth.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$DEX_ROOT/script/network/$network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# 上一次异常退出可能留下地址临时文件；只清理本模块的隐藏临时模式，不碰正式地址文件。
rm -f "$NETWORK_DIR/.addresses.weth.params."*

for config in network.params dex.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

# 清掉可能从调用者环境继承来的取值，避免用别的网络的配置部署。
export WETH_ADDRESS="" WETH_NAME="" WETH_SYMBOL=""

set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/dex.params"
set +a

# 实际链必须与配置一致。
actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$actual_chain_id" = "$CHAIN_ID" ] || { echo "Error: chain ID mismatch: config=$CHAIN_ID rpc=$actual_chain_id" >&2; exit 1; }

weth_address="${WETH_ADDRESS:-}"
weth_name="${WETH_NAME:-}"
weth_symbol="${WETH_SYMBOL:-}"
ADDRESS_TMP="$NETWORK_DIR/.addresses.weth.params.$$"

# 外部 WETH 模式：WETH_ADDRESS 与 WETH_NAME/WETH_SYMBOL 互斥。
if [ -n "$weth_address" ]; then
    if [ -n "$weth_name" ] || [ -n "$weth_symbol" ]; then
        echo "Error: WETH_ADDRESS and WETH_NAME/WETH_SYMBOL are mutually exclusive." >&2
        exit 1
    fi
    if [[ ! "$weth_address" =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ "$weth_address" = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: invalid WETH_ADDRESS: $weth_address" >&2
        exit 1
    fi
    weth_code=$(cast code "$weth_address" --rpc-url "$RPC_URL" 2>/dev/null) || true
    if [[ ! "$weth_code" =~ ^0x[0-9a-fA-F]+$ ]]; then
        echo "Error: WETH_ADDRESS $weth_address is not a deployed contract on chain $CHAIN_ID" >&2
        exit 1
    fi
    trap 'rm -f "$ADDRESS_TMP"' EXIT
    printf 'WETH_ADDRESS=%s\n' "$weth_address" > "$ADDRESS_TMP"
    mv "$ADDRESS_TMP" "$NETWORK_DIR/addresses.weth.params"
    echo "Using external WETH: $weth_address"
    exit 0
fi

# 本地部署模式：WETH_ADDRESS 必须为空，name/symbol 必须成对提供；只有需要广播时才要求 .account。
if [ -z "$weth_name" ] || [ -z "$weth_symbol" ]; then
    echo "Error: WETH_ADDRESS is empty; both WETH_NAME and WETH_SYMBOL are required for a local WETH deployment." >&2
    exit 1
fi
if [ ! -f "$NETWORK_DIR/.account" ]; then
    echo "Error: Missing required configuration: $NETWORK_DIR/.account" >&2
    exit 1
fi

env_password="${KEYSTORE_PASSWORD:-}"
set -a
source "$NETWORK_DIR/.account"
set +a

# .account 里的空 KEYSTORE_PASSWORD 行不应清掉入口已导出的密码（避免重复弹窗）。
[ -n "${KEYSTORE_PASSWORD:-}" ] || KEYSTORE_PASSWORD="$env_password"

[ -n "${KEYSTORE_ACCOUNT:-}" ] && [ -n "${ACCOUNT_ADDRESS:-}" ] \
    || { echo "Error: KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS is not set in $NETWORK_DIR/.account" >&2; exit 1; }

# 已设 KEYSTORE_PASSWORD 则不弹窗（非交互调用用）。
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
trap 'rm -f "$PASSWORD_FILE" "$ADDRESS_TMP"' EXIT
chmod 600 "$PASSWORD_FILE"
printf '%s' "$KEYSTORE_PASSWORD" > "$PASSWORD_FILE"

# 地址文件先写隐藏临时文件，成功后再 mv，避免写失败截断旧记录。
# 地址文件路径相对 DEX_ROOT：forge 以项目根为工作目录执行（vm.writeFile 只允许项目内路径）。
export ADDRESSES_FILE="script/network/$network/.addresses.weth.params.$$"

echo "Network: $network (chain $CHAIN_ID)"
cd "$DEX_ROOT"
echo "Deploying WETH to $network..."
forge script script/DeployWETH.s.sol:DeployWETH --sig "run()" \
    --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" \
    --password-file "$PASSWORD_FILE" --broadcast --legacy
# 密码只在本次 forge 调用期间需要，广播结束立即删除。
rm -f "$PASSWORD_FILE"
mv "$ADDRESS_TMP" "$NETWORK_DIR/addresses.weth.params"

source "$NETWORK_DIR/addresses.weth.params"
echo "✓ WETH: $WETH_ADDRESS"
