#!/usr/bin/env bash

# 独立复核（WETH 模块）：只读参数文件与链上取值，核对 WETH 的名称、符号与部署状态。
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

# 清掉可能从调用者环境继承来的取值；dex.params 配置了 WETH 地址（公共链）才使用它。
WETH_ADDRESS=""
source "$network_dir/network.params"
source "$network_dir/dex.params"
# 记录 dex.params 是否配置了 WETH 地址：未配置表示本次本地部署的是上游 WETH9，名称符号期望不同。
weth_configured="${WETH_ADDRESS:-}"
source "$network_dir/addresses.weth.params"

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

actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$actual_chain_id" = "$CHAIN_ID" ] || { echo "Error: chain ID mismatch: config=$CHAIN_ID rpc=$actual_chain_id" >&2; exit 1; }

# 本地部署的 WETH 是上游 WETH9；配置了地址的是链上官方合约（BSC 上为 WBNB）。
# cast 的 string 返回值自带引号，故期望值按带引号字面量写。
if [ -n "$weth_configured" ]; then
    expected_name='"Wrapped BNB"'
    expected_symbol='"WBNB"'
else
    expected_name='"Wrapped Ether"'
    expected_symbol='"WETH"'
fi

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

check "WETH 名称" "$WETH_ADDRESS" "name()(string)" "$expected_name"
check "WETH 符号" "$WETH_ADDRESS" "symbol()(string)" "$expected_symbol"

weth_code=$(cast code "$WETH_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null) || true
if [[ ! "$weth_code" =~ ^0x[0-9a-fA-F]+$ ]]; then
    failed=$((failed + 1))
    echo "✗ WETH 未部署: $WETH_ADDRESS"
else
    echo "✓ WETH 已部署"
fi

if [ "$failed" -ne 0 ]; then
    echo "✗ $failed 项不符" >&2
    exit 1
fi
echo "✓ WETH verified"
