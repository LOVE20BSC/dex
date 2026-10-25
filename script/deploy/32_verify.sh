#!/usr/bin/env bash
set -euo pipefail

# 步骤三（UniswapV2 模块）：合约开源验证。自包含——自行载入 network.params 与两个模块的
# 地址文件（WETH_ADDRESS 取自 addresses.weth.params），不依赖入口脚本在部署后刷新地址。
# WETH 不在本步骤验证：外部 WETH 由对方维护；本地部署的 WETH 由 31_verify_weth.sh 验证。
# 用法：script/deploy/32_verify.sh <network>

network="${1:?usage: script/deploy/32_verify.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$DEX_ROOT/script/network/$network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params addresses.weth.params addresses.uniswapv2.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/addresses.weth.params"
source "$NETWORK_DIR/addresses.uniswapv2.params"
set +a

cd "$DEX_ROOT"

# 链不支持开源验证时跳过，不视为失败，使一键部署在本地/未接入浏览器的链上仍可跑通。
case "$CHAIN_ID" in
    56|97) ;;
    *) echo "Skip: source verification is not configured for chain $CHAIN_ID"; exit 0 ;;
esac
: "${ETHERSCAN_API_KEY:?Set an Etherscan API key; source verification has not run.}"

# 按模块分组校验地址字段来源：WETH 来自 WETH 模块文件，Factory/Router 来自 UniswapV2 模块文件。
for field in WETH_ADDRESS; do
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Missing or invalid $field in $NETWORK_DIR/addresses.weth.params"
        exit 1
    fi
done
for field in FACTORY_ADDRESS ROUTER_ADDRESS; do
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Missing or invalid $field in $NETWORK_DIR/addresses.uniswapv2.params"
        exit 1
    fi
done

# Factory 的 feeToSetter 固定为 address(0)（永久放弃协议抽成，见 docs/adr/0001）；
# Router02 绑定本次部署的 Factory 与 WETH。
# 命令替换失败在 set -e 下会静默中止，故逐个显式判别，保证失败有明确输出。
if ! FACTORY_ARGS=$(cast abi-encode "constructor(address)" 0x0000000000000000000000000000000000000000); then
    echo "Error: Failed to encode Factory constructor arguments"
    exit 1
fi
if ! ROUTER_ARGS=$(cast abi-encode "constructor(address,address)" "$FACTORY_ADDRESS" "$WETH_ADDRESS"); then
    echo "Error: Failed to encode Router02 constructor arguments"
    exit 1
fi

COMMON_ARGS=(--chain "$CHAIN_ID" --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api" --watch)
verify_contract() {
    local address=$1 source=$2 name=$3
    shift 3
    echo "Verifying $name..."
    forge verify-contract "$address" "$source:$name" "${COMMON_ARGS[@]}" "$@"
}

# 只验证本仓库部署的两份合约。WETH 不在此验证：公共链上是官方既有合约
# （BSC 上为官方 WBNB），其编译设置与本仓库不同，按本地源码提交必然失败；
# 本地链（未配置 WETH_ADDRESS）的 WETH9 随整链跳过开源验证，无可验证场景。
verify_contract "$FACTORY_ADDRESS" lib/v2-core/contracts/UniswapV2Factory.sol UniswapV2Factory --constructor-args "$FACTORY_ARGS"
verify_contract "$ROUTER_ADDRESS" lib/v2-periphery/contracts/UniswapV2Router02.sol UniswapV2Router02 --constructor-args "$ROUTER_ARGS"
echo "✓ Source verification succeeded for Factory and Router02"
