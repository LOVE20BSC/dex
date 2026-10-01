#!/usr/bin/env bash

# 步骤 1：部署 Uniswap V2 Factory 与 Router02，地址由 Deploy.s.sol 写入 addresses.dex.params。
# 前置：环境已由拼装脚本载入（source 00_init.sh），单独执行会因变量未定义立即失败。

set -euo pipefail

cd "$DEX_ROOT"
echo "Deploying Uniswap V2 Factory and Router02 to $network..."
forge script script/Deploy.s.sol:Deploy --sig "run()" \
    --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" \
    --password "$KEYSTORE_PASSWORD" --broadcast --legacy

source "$network_dir/addresses.dex.params"
echo "✓ WBNB: $WBNB_ADDRESS"
echo "✓ Factory: $FACTORY_ADDRESS"
echo "✓ Router02: $ROUTER_ADDRESS"
