#!/usr/bin/env bash
set -euo pipefail

# 步骤一（WETH 模块）：就绪 WETH。自包含——自行加载并校验部署所需文件，不依赖调用方预载环境。
# WETH_ADDRESS 是必填的模式开关（零地址=本地部署）：
#   WETH_ADDRESS 非零：使用外部已部署 WETH，不部署、不需要 keystore；
#   WETH_ADDRESS 为零地址：必须提供 WETH_NAME 与 WETH_SYMBOL，部署一个可配置名称/符号的 WETH。
# 缺键或空值直接失败，不回落任一分支——漏配外部地址不能静默变成「部署一个本地 WETH」。
# 部署期静态校验（互斥、有代码、decimals/deposit/withdraw、本地名称/符号）在
# DeployWETH.s.sol 的广播前阶段完成；本步骤只做文件、链、账户与密码编排。
# 地址写入 addresses.weth.params，供 UniswapV2 模块与校验步骤载入。
# 用法：script/deploy/11_deploy_weth.sh <network>

network="${1:?usage: script/deploy/11_deploy_weth.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$DEX_ROOT/script/network/$network"

# 参数文件载入器：1e17 / 1_000_000 这类写法在载入时展开为十进制（见 params.sh）。
source "$SCRIPT_DIR/params.sh"

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
unset WETH_ADDRESS WETH_NAME WETH_SYMBOL

params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/dex.params"

weth_address="${WETH_ADDRESS:-}"
zero_address=0x0000000000000000000000000000000000000000
if [ -z "$weth_address" ]; then
    echo "Error: WETH_ADDRESS must be set in $NETWORK_DIR/dex.params (use $zero_address to deploy locally)" >&2
    exit 1
fi
if [ "$(printf '%s' "$weth_address" | tr '[:upper:]' '[:lower:]')" = "$zero_address" ]; then
    weth_mode=local
else
    weth_mode=external
fi

# 实际链必须与配置一致。
actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$actual_chain_id" = "$CHAIN_ID" ] || { echo "Error: chain ID mismatch: config=$CHAIN_ID rpc=$actual_chain_id" >&2; exit 1; }

ADDRESS_TMP="$NETWORK_DIR/.addresses.weth.params.$$"
export ADDRESSES_FILE="script/network/$network/.addresses.weth.params.$$"

echo "Network: $network (chain $CHAIN_ID)"
cd "$DEX_ROOT"

if [ "$weth_mode" = external ]; then
    # 外部 WETH 模式：只读模拟运行 Solidity 脚本完成接口校验，不广播、不读取 keystore。
    trap 'rm -f "$ADDRESS_TMP"' EXIT
    echo "Using external WETH: $weth_address"
    if ! forge script script/deploy/DeployWETH.s.sol:DeployWETH --sig "run()" \
        --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" -vvv; then
        echo "Error: External WETH validation failed." >&2
        exit 1
    fi
else
    # 本地部署模式：只有需要广播时才要求 .account 与密码。
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

    # 密码经临时文件传给 forge：--password 会把明文放进进程参数，同机其他用户可直接读到。
    # trap 在写入密码之前安装，chmod/printf 失败也不会留下明文。
    PASSWORD_FILE=$(mktemp)
    trap 'rm -f "$PASSWORD_FILE" "$ADDRESS_TMP"' EXIT
    chmod 600 "$PASSWORD_FILE"
    printf '%s' "$KEYSTORE_PASSWORD" > "$PASSWORD_FILE"

    DEPLOY_START_EPOCH_SECONDS=$(date +%s)
    echo "Deploying WETH to $network..."
    if ! forge script script/deploy/DeployWETH.s.sol:DeployWETH --sig "run()" \
        --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
        --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" \
        --password-file "$PASSWORD_FILE" --broadcast --legacy -vvv; then
        echo "Error: WETH deployment failed." >&2
        exit 1
    fi
    rm -f "$PASSWORD_FILE"

    BROADCAST_FILE="$DEX_ROOT/broadcast/DeployWETH.s.sol/$CHAIN_ID/run-latest.json"
    if [ ! -f "$BROADCAST_FILE" ]; then
        echo "Error: Missing broadcast artifact: $BROADCAST_FILE" >&2
        exit 1
    fi
    BROADCAST_TIMESTAMP_MS=$(sed -nE 's/.*"timestamp":[[:space:]]*([0-9]+).*/\1/p' "$BROADCAST_FILE" | tail -1)
    if [ -z "$BROADCAST_TIMESTAMP_MS" ] || [ "$BROADCAST_TIMESTAMP_MS" -lt "$((DEPLOY_START_EPOCH_SECONDS * 1000))" ]; then
        echo "Error: Broadcast artifact was not updated by this deployment: $BROADCAST_FILE" >&2
        exit 1
    fi
fi

if [ ! -f "$ADDRESS_TMP" ]; then
    echo "Error: DeployWETH.s.sol did not write $ADDRESS_TMP" >&2
    exit 1
fi
deployed_weth=$(sed -nE 's/^WETH_ADDRESS=(.*)$/\1/p' "$ADDRESS_TMP" | tail -1 | xargs || true)
if [[ ! "$deployed_weth" =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ "$deployed_weth" = 0x0000000000000000000000000000000000000000 ]]; then
    echo "Error: Invalid WETH_ADDRESS in $ADDRESS_TMP" >&2
    exit 1
fi
printf 'WETH_ADDRESS=%s\n' "$deployed_weth" > "$ADDRESS_TMP"
mv "$ADDRESS_TMP" "$NETWORK_DIR/addresses.weth.params"

echo "✓ WETH: $deployed_weth"
