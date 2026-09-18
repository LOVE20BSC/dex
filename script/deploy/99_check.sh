#!/usr/bin/env bash

[ -n "${FACTORY_ADDRESS:-}" ] || { echo "Factory address is not set"; return 1 2>/dev/null || exit 1; }
[ -n "${ROUTER_ADDRESS:-}" ] || { echo "Router address is not set"; return 1 2>/dev/null || exit 1; }

echo "Checking deployed DEX..."
[ "$(cast code "$FACTORY_ADDRESS" --rpc-url "$RPC_URL")" != "0x" ] || { echo "✗ Factory has no code"; return 1 2>/dev/null || exit 1; }
[ "$(cast code "$ROUTER_ADDRESS" --rpc-url "$RPC_URL")" != "0x" ] || { echo "✗ Router has no code"; return 1 2>/dev/null || exit 1; }
check_equal "Factory feeTo" 0x0000000000000000000000000000000000000000 "$(cast_call "$FACTORY_ADDRESS" "feeTo()(address)")" || return 1
check_equal "Factory feeToSetter" 0x0000000000000000000000000000000000000000 "$(cast_call "$FACTORY_ADDRESS" "feeToSetter()(address)")" || return 1
check_equal "Router factory" "$FACTORY_ADDRESS" "$(cast_call "$ROUTER_ADDRESS" "factory()(address)")" || return 1
check_equal "Router WETH" "$WBNB_ADDRESS" "$(cast_call "$ROUTER_ADDRESS" "WETH()(address)")" || return 1
echo "✓ Deployment checks passed"
