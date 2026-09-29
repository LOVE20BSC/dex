#!/usr/bin/env bash

[ -n "${RPC_URL:-}" ] || { echo "Run: source 00_init.sh <network>"; return 1 2>/dev/null || exit 1; }

echo "Deploying Uniswap V2 Factory and Router02..."
forge_script script/Deploy.s.sol:Deploy --sig "run()" || return 1
[ -f "$network_dir/addresses.dex.params" ] || { echo "Deployment did not write $network_dir/addresses.dex.params"; return 1; }
source "$network_dir/addresses.dex.params" || return 1
echo "✓ Factory: $FACTORY_ADDRESS"
echo "✓ Router02: $ROUTER_ADDRESS"
