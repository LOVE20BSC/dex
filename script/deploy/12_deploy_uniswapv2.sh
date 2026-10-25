#!/usr/bin/env bash
set -euo pipefail

# 步骤二（UniswapV2 模块）：部署 Factory 与 Router02，地址写入 addresses.uniswapv2.params。
# 自包含——自行加载并校验部署所需文件，不依赖调用方预载环境。
# WETH 地址取自 WETH 模块写出的 addresses.weth.params（先跑 11_deploy_weth.sh）；
# WETH 是否有代码、Factory/Router 字节码哈希与部署后绑定由 DeployUniswapV2.s.sol 在广播前后校验。
# 用法：script/deploy/12_deploy_uniswapv2.sh <network>

network="${1:?usage: script/deploy/12_deploy_uniswapv2.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$DEX_ROOT/script/network/$network"

# 参数文件载入器：1e17 / 1_000_000 这类写法在载入时展开为十进制（见 params.sh）。
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

rm -f "$NETWORK_DIR/.addresses.uniswapv2.params."*

for config in network.params addresses.weth.params .account; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config (run 11_deploy_weth.sh first)"
        exit 1
    fi
done

env_password="${KEYSTORE_PASSWORD:-}"
params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/addresses.weth.params"
# .account 走普通 source：密码可能含 "#"，不能经过参数展开。
set -a
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

# 密码经临时文件传给 forge：--password 会把明文放进进程参数，同机其他用户可直接读到。
PASSWORD_FILE=$(mktemp)
ADDRESS_TMP="$NETWORK_DIR/.addresses.uniswapv2.params.$$"
export ADDRESSES_FILE="script/network/$network/.addresses.uniswapv2.params.$$"
trap 'rm -f "$PASSWORD_FILE" "$ADDRESS_TMP"' EXIT
chmod 600 "$PASSWORD_FILE"
printf '%s' "$KEYSTORE_PASSWORD" > "$PASSWORD_FILE"

echo "Network: $network (chain $CHAIN_ID)"
cd "$DEX_ROOT"
DEPLOY_START_EPOCH_SECONDS=$(date +%s)
echo "Deploying Uniswap V2 Factory and Router02 to $network..."
if ! forge script script/deploy/DeployUniswapV2.s.sol:DeployUniswapV2 --sig "run()" \
    --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
    --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" \
    --password-file "$PASSWORD_FILE" --broadcast --legacy -vvv; then
    echo "Error: UniswapV2 deployment failed." >&2
    exit 1
fi
# 密码只在本次 forge 调用期间需要，广播结束立即删除。
rm -f "$PASSWORD_FILE"

BROADCAST_FILE="$DEX_ROOT/broadcast/DeployUniswapV2.s.sol/$CHAIN_ID/run-latest.json"
if [ ! -f "$BROADCAST_FILE" ]; then
    echo "Error: Missing broadcast artifact: $BROADCAST_FILE" >&2
    exit 1
fi
BROADCAST_TIMESTAMP_MS=$(sed -nE 's/.*"timestamp":[[:space:]]*([0-9]+).*/\1/p' "$BROADCAST_FILE" | tail -1)
if [ -z "$BROADCAST_TIMESTAMP_MS" ] || [ "$BROADCAST_TIMESTAMP_MS" -lt "$((DEPLOY_START_EPOCH_SECONDS * 1000))" ]; then
    echo "Error: Broadcast artifact was not updated by this deployment: $BROADCAST_FILE" >&2
    exit 1
fi

if [ ! -f "$ADDRESS_TMP" ]; then
    echo "Error: DeployUniswapV2.s.sol did not write $ADDRESS_TMP" >&2
    exit 1
fi
factory_address=$(sed -nE 's/^FACTORY_ADDRESS=(.*)$/\1/p' "$ADDRESS_TMP" | tail -1 | xargs || true)
router_address=$(sed -nE 's/^ROUTER_ADDRESS=(.*)$/\1/p' "$ADDRESS_TMP" | tail -1 | xargs || true)
for pair in "FACTORY_ADDRESS:$factory_address" "ROUTER_ADDRESS:$router_address"; do
    field="${pair%%:*}"
    value="${pair#*:}"
    if [[ ! "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ "$value" = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Invalid $field in $ADDRESS_TMP" >&2
        exit 1
    fi
done
{
    printf 'FACTORY_ADDRESS=%s\n' "$factory_address"
    printf 'ROUTER_ADDRESS=%s\n' "$router_address"
} > "$ADDRESS_TMP"
mv "$ADDRESS_TMP" "$NETWORK_DIR/addresses.uniswapv2.params"

echo "✓ Factory: $factory_address"
echo "✓ Router02: $router_address"
