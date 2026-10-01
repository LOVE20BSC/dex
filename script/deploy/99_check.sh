#!/usr/bin/env bash

# 独立复核：只读参数文件与 addresses.dex.params，核对链上取值。
# 六项全部跑完再汇总，不中途退出；不读 .account、不需要密码，可随时重跑。
# 用法：script/deploy/99_check.sh <network>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

network="${1:?usage: script/deploy/99_check.sh <network>}"
network_dir="$DEX_ROOT/script/network/$network"
[ -d "$network_dir" ] || { echo "Error: unknown network: $network" >&2; exit 1; }
source "$network_dir/network.params"
source "$network_dir/dex.params"
source "$network_dir/addresses.dex.params"

actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$actual_chain_id" = "$CHAIN_ID" ] || { echo "Error: chain ID mismatch: config=$CHAIN_ID rpc=$actual_chain_id" >&2; exit 1; }

# TestWBNB 是上游 WETH9；cast 的 string 返回值自带引号，故期望值按带引号字面量写。
if [ "${DEPLOY_TEST_WBNB:-false}" = "true" ]; then
    expected_name='"Wrapped Ether"'
    expected_symbol='"WETH"'
else
    expected_name='"Wrapped BNB"'
    expected_symbol='"WBNB"'
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

check "WBNB 名称" "$WBNB_ADDRESS" "name()(string)" "$expected_name"
check "WBNB 符号" "$WBNB_ADDRESS" "symbol()(string)" "$expected_symbol"
check "Factory 抽成收款地址为零 (feeTo)" "$FACTORY_ADDRESS" "feeTo()(address)" 0x0000000000000000000000000000000000000000
check "Factory 抽成管理员为零 (feeToSetter)" "$FACTORY_ADDRESS" "feeToSetter()(address)" 0x0000000000000000000000000000000000000000
check "Router 使用本 Factory (factory)" "$ROUTER_ADDRESS" "factory()(address)" "$FACTORY_ADDRESS"
check "Router 使用本 WBNB (WETH)" "$ROUTER_ADDRESS" "WETH()(address)" "$WBNB_ADDRESS"

if [ "$failed" -ne 0 ]; then
    echo "✗ $failed 项不符" >&2
    exit 1
fi
echo "✓ Deployment verified"
