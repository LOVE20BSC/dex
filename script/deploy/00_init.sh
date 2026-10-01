#!/usr/bin/env bash

# 步骤 0：初始化。由 one_click_* 拼装脚本在同一 shell 里 source，负责载入网络配置、
# 校验链 ID、准备 keystore 密码，并把后续步骤需要的变量导出到环境。
# 之所以用 source：子进程之间无法传递 shell 变量，后续步骤是被执行的子进程。
# 用法（只由拼装脚本调用）：source script/deploy/00_init.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

network="${1:?usage: source script/deploy/00_init.sh <network>}"
network_dir="$DEX_ROOT/script/network/$network"
[ -d "$network_dir" ] || { echo "Error: unknown network: $network" >&2; exit 1; }

# 清掉可能从调用者环境继承来的取值，避免用别的网络的配置部署。
WBNB_ADDRESS=""
DEPLOY_TEST_WBNB=false
source "$network_dir/network.params"
source "$network_dir/dex.params"
source "$network_dir/.account"
[ -n "${KEYSTORE_ACCOUNT:-}" ] && [ -n "${ACCOUNT_ADDRESS:-}" ] \
    || { echo "Error: KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS is not set in $network_dir/.account" >&2; exit 1; }

# 实际链必须与配置一致；已设 KEYSTORE_PASSWORD 则不弹窗（非交互调用用）。
actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$actual_chain_id" = "$CHAIN_ID" ] || { echo "Error: chain ID mismatch: config=$CHAIN_ID rpc=$actual_chain_id" >&2; exit 1; }
if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for $KEYSTORE_ACCOUNT:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
fi

# 后续步骤以子进程执行，通过环境读取这些值。
export network network_dir DEX_ROOT CHAIN_ID RPC_URL DEPLOY_TEST_WBNB WBNB_ADDRESS
export KEYSTORE_ACCOUNT ACCOUNT_ADDRESS KEYSTORE_PASSWORD
export ADDRESSES_FILE="script/network/$network/addresses.dex.params"

echo "Network: $network (chain $CHAIN_ID)"
