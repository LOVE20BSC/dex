#!/usr/bin/env bash

# 独立复核（WETH 模块）：只读参数文件与链上取值，核对 WETH 的部署状态；
# 两种模式都校验地址、decimals 与 deposit/withdraw；本地部署模式另校验名称与符号。
# 用法：script/deploy/21_check_weth.sh <network>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

network="${1:?usage: script/deploy/21_check_weth.sh <network>}"
network_dir="$DEX_ROOT/script/network/$network"
[ -d "$network_dir" ] || { echo "Error: unknown network: $network" >&2; exit 1; }

for config in network.params dex.params addresses.weth.params; do
    [ -f "$network_dir/$config" ] || { echo "Error: missing $network_dir/$config" >&2; exit 1; }
done

# 清掉可能从调用者环境继承来的取值；名称/符号来自 dex.params，地址以地址文件为准。
WETH_ADDRESS="" WETH_NAME="" WETH_SYMBOL=""
source "$network_dir/network.params"
source "$network_dir/dex.params"
configured_weth_address="${WETH_ADDRESS:-}"
configured_weth_name="${WETH_NAME:-}"
configured_weth_symbol="${WETH_SYMBOL:-}"

# 三参数严格二选一：地址单独有值，或 name+symbol 同时有值；不能同时有、全空或只给一个。
if [ -n "$configured_weth_address" ]; then
    if [ -n "$configured_weth_name" ] || [ -n "$configured_weth_symbol" ]; then
        echo "Error: WETH_ADDRESS and WETH_NAME/WETH_SYMBOL are mutually exclusive in $network_dir/dex.params" >&2
        exit 1
    fi
else
    if [ -z "$configured_weth_name" ] || [ -z "$configured_weth_symbol" ]; then
        echo "Error: WETH_ADDRESS is empty; both WETH_NAME and WETH_SYMBOL are required in $network_dir/dex.params" >&2
        exit 1
    fi
fi

# 地址文件的键集合必须与期望合约集合一致：键名漏改会让后续变量静默为空，
# 逐项 cast 调用要到很后面才以难以定位的形式失败，故在此显式断言。
address_file="$network_dir/addresses.weth.params"
expected_keys="WETH_ADDRESS"
actual_keys=$(grep -oE '^[A-Z0-9_]+=' "$address_file" | sed 's/=$//' | sort | tr '\n' ' ' || true)
if [ "$actual_keys" != "$(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" ]; then
    echo "Error: $address_file key set mismatch" >&2
    echo "  expected: $(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" >&2
    echo "  actual:   $actual_keys" >&2
    exit 1
fi

source "$network_dir/addresses.weth.params"
if [ -n "$configured_weth_address" ]; then
    actual_configured_address="$(printf '%s' "$WETH_ADDRESS" | tr '[:upper:]' '[:lower:]')"
    expected_configured_address="$(printf '%s' "$configured_weth_address" | tr '[:upper:]' '[:lower:]')"
    if [ "$actual_configured_address" != "$expected_configured_address" ]; then
        echo "Error: $network_dir/addresses.weth.params WETH_ADDRESS does not match dex.params WETH_ADDRESS" >&2
        exit 1
    fi
fi

actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$actual_chain_id" = "$CHAIN_ID" ] || { echo "Error: chain ID mismatch: config=$CHAIN_ID rpc=$actual_chain_id" >&2; exit 1; }

failed=0
check() {
    local name="$1" address="$2" signature="$3" expected="$4" actual
    actual="$(cast call "$address" "$signature" --rpc-url "$RPC_URL" 2>/dev/null || echo ERROR)"
    if [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]; then
        echo "✓ $name = $actual"
        return
    fi
    failed=$((failed + 1))
    echo "✗ $name"
    echo "    合约: $address"
    echo "    调用: $signature"
    echo "    实际: $actual"
    echo "    期望: $expected"
}

# 外部 WETH 模式只校验地址；本地部署模式校验配置的名称与符号。
if [ -n "$configured_weth_address" ]; then
    echo "Skip WETH 名称/符号（外部 WETH 只校验地址）"
else
    check "WETH 名称" "$WETH_ADDRESS" "name()(string)" "\"$configured_weth_name\""
    check "WETH 符号" "$WETH_ADDRESS" "symbol()(string)" "\"$configured_weth_symbol\""
fi

weth_code=$(cast code "$WETH_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null) || true
if [[ ! "$weth_code" =~ ^0x[0-9a-fA-F]+$ ]]; then
    failed=$((failed + 1))
    echo "✗ WETH 未部署: $WETH_ADDRESS"
else
    echo "✓ WETH 已部署"
fi

weth_probe_from=0x000000000000000000000000000000000000dEaD
weth_decimals=$(cast call "$WETH_ADDRESS" "decimals()(uint8)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
if [ "$weth_decimals" = "18" ]; then
    echo "✓ WETH decimals = 18"
else
    failed=$((failed + 1))
    echo "✗ WETH decimals (actual: $weth_decimals)"
fi
if cast call "$WETH_ADDRESS" "deposit()" --from "$weth_probe_from" --rpc-url "$RPC_URL" >/dev/null 2>&1 \
    && cast call "$WETH_ADDRESS" "withdraw(uint256)" 0 --from "$weth_probe_from" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    echo "✓ WETH deposit/withdraw"
else
    failed=$((failed + 1))
    echo "✗ WETH deposit/withdraw"
fi

if [ "$failed" -ne 0 ]; then
    echo "✗ $failed 项不符" >&2
    exit 1
fi
echo "✓ WETH verified"
