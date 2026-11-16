#!/usr/bin/env bash

# Independent check (UniswapV2 module): reads only the parameter files and chain state to
# verify the Factory/Router02 bindings.
# Usage: script/deploy/22_check_uniswapv2.sh <network>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

network="${1:?usage: script/deploy/22_check_uniswapv2.sh <network>}"
network_dir="$DEX_ROOT/script/network/$network"
[ -d "$network_dir" ] || { echo "Error: unknown network: $network" >&2; exit 1; }

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

for config in network.params addresses.weth.params addresses.uniswapv2.params; do
    [ -f "$network_dir/$config" ] || { echo "Error: missing $network_dir/$config" >&2; exit 1; }
done

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value. dex.params is not loaded here: this module reads WETH_ADDRESS
# from addresses.weth.params, which is the deployed record, and the name/symbol keys only configure
# a local WETH deployment.
params_unset_all "$network_dir/network.params" "$network_dir/addresses.weth.params" \
    "$network_dir/addresses.uniswapv2.params"

params_load "$network_dir/network.params"
if [ -f "$network_dir/.account" ]; then
    set -a
    source "$network_dir/.account"
    set +a
fi
params_load "$network_dir/addresses.weth.params"
params_load "$network_dir/addresses.uniswapv2.params"

# The address file's key set must equal the expected contract set: a renamed key would leave later
# variables silently empty and fail much later with an unhelpful message, so assert it here.
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
    echo "    contract: $address"
    echo "    call: $signature"
    echo "    actual: $actual"
    echo "    expected: $expected"
}

check "Factory feeTo is zero" "$FACTORY_ADDRESS" "feeTo()(address)" 0x0000000000000000000000000000000000000000
check "Factory feeToSetter is zero" "$FACTORY_ADDRESS" "feeToSetter()(address)" 0x0000000000000000000000000000000000000000
check "Router factory is this Factory" "$ROUTER_ADDRESS" "factory()(address)" "$FACTORY_ADDRESS"
check "Router WETH is this WETH" "$ROUTER_ADDRESS" "WETH()(address)" "$WETH_ADDRESS"

if [ "$failed" -ne 0 ]; then
    echo "✗ $failed check(s) failed" >&2
    exit 1
fi
echo "✓ UniswapV2 verified"
