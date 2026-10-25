#!/usr/bin/env bash

# 独立复核（UniswapV2 模块）：只读参数文件与链上取值，核对 Factory 与 Router02 的绑定关系。
# 用法：script/deploy/22_check_uniswapv2.sh <network>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

network="${1:?usage: script/deploy/22_check_uniswapv2.sh <network>}"
network_dir="$DEX_ROOT/script/network/$network"
[ -d "$network_dir" ] || { echo "Error: unknown network: $network" >&2; exit 1; }

# 参数文件载入器：1e17 / 1_000_000 这类写法在载入时展开为十进制（见 params.sh）。
source "$SCRIPT_DIR/params.sh"

for config in network.params dex.params addresses.weth.params addresses.uniswapv2.params; do
    [ -f "$network_dir/$config" ] || { echo "Error: missing $network_dir/$config" >&2; exit 1; }
done

params_load "$network_dir/network.params"
params_load "$network_dir/dex.params"
params_load "$network_dir/addresses.weth.params"
params_load "$network_dir/addresses.uniswapv2.params"

# 地址文件的键集合必须与期望合约集合一致：键名漏改会让后续变量静默为空，
# 逐项 cast 调用要到很后面才以难以定位的形式失败，故在此显式断言。
assert_key_set() {
    local address_file="$1" expected_keys="$2" actual_keys
    actual_keys=$(grep -oE '^[A-Z0-9_]+=' "$address_file" | sed 's/=$//' | sort | tr '\n' ' ' || true)
    if [ "$actual_keys" != "$(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" ]; then
        echo "Error: $address_file key set mismatch" >&2
        echo "  expected: $(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" >&2
        echo "  actual:   $actual_keys" >&2
        exit 1
    fi
}
assert_key_set "$network_dir/addresses.weth.params" "WETH_ADDRESS"
assert_key_set "$network_dir/addresses.uniswapv2.params" "FACTORY_ADDRESS ROUTER_ADDRESS"

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

check "Factory 抽成收款地址为零 (feeTo)" "$FACTORY_ADDRESS" "feeTo()(address)" 0x0000000000000000000000000000000000000000
check "Factory 抽成管理员为零 (feeToSetter)" "$FACTORY_ADDRESS" "feeToSetter()(address)" 0x0000000000000000000000000000000000000000
check "Router 使用本 Factory (factory)" "$ROUTER_ADDRESS" "factory()(address)" "$FACTORY_ADDRESS"
check "Router 使用本 WETH (WETH)" "$ROUTER_ADDRESS" "WETH()(address)" "$WETH_ADDRESS"

if [ "$failed" -ne 0 ]; then
    echo "✗ $failed 项不符" >&2
    exit 1
fi
echo "✓ UniswapV2 verified"
