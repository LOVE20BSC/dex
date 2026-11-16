#!/usr/bin/env bash

# Independent check (WETH module): reads only the parameter files and chain state to verify the
# WETH deployment. Both modes verify the address, decimals and deposit/withdraw; local deployment
# mode also verifies name and symbol.
# Usage: script/deploy/21_check_weth.sh <network>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

network="${1:?usage: script/deploy/21_check_weth.sh <network>}"
network_dir="$DEX_ROOT/script/network/$network"
[ -d "$network_dir" ] || { echo "Error: unknown network: $network" >&2; exit 1; }

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

for config in network.params dex.params addresses.weth.params; do
    [ -f "$network_dir/$config" ] || { echo "Error: missing $network_dir/$config" >&2; exit 1; }
done

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value. WETH_ADDRESS is the mode switch, and an empty value reads as
# neither "external" nor "local", so it is asserted against the file itself, never against the
# variable - an inherited value could satisfy that.
params_require_values "$network_dir/dex.params" WETH_ADDRESS || exit 1

# WETH_NAME/WETH_SYMBOL only configure a local deployment; an inherited value must not survive a
# profile that omits them, or a correct external-mode configuration would be reported as mutually
# exclusive. params_unset_all only knows the keys the files still define, so clear these two
# explicitly before loading; a value the file does define is loaded again below and still rejected
# when it contradicts WETH_ADDRESS.
unset WETH_NAME WETH_SYMBOL

params_unset_all "$network_dir/network.params" "$network_dir/dex.params" \
    "$network_dir/addresses.weth.params"

params_load "$network_dir/network.params"
if [ -f "$network_dir/.account" ]; then
    set -a
    source "$network_dir/.account"
    set +a
fi
params_load "$network_dir/dex.params"
configured_weth_address="${WETH_ADDRESS:-}"
configured_weth_name="${WETH_NAME:-}"
configured_weth_symbol="${WETH_SYMBOL:-}"
zero_address=0x0000000000000000000000000000000000000000

# WETH_ADDRESS is a mandatory mode switch (zero address = deploy locally); a missing key or an empty
# value fails instead of continuing in either mode.
if [ -z "$configured_weth_address" ]; then
    echo "Error: WETH_ADDRESS must be set in $network_dir/dex.params (use $zero_address to deploy locally)" >&2
    exit 1
fi
if [ "$(printf '%s' "$configured_weth_address" | tr '[:upper:]' '[:lower:]')" = "$zero_address" ]; then
    configured_weth_external=0
else
    configured_weth_external=1
fi

# Exactly one of the two shapes: a non-zero address alone, or a zero address with both name and
# symbol; never both, never all empty, never just one.
if [ "$configured_weth_external" -eq 1 ]; then
    if [ -n "$configured_weth_name" ] || [ -n "$configured_weth_symbol" ]; then
        echo "Error: WETH_ADDRESS and WETH_NAME/WETH_SYMBOL are mutually exclusive in $network_dir/dex.params" >&2
        exit 1
    fi
else
    params_require_keys "$network_dir/dex.params" WETH_NAME WETH_SYMBOL || exit 1
    if [ -z "$configured_weth_name" ] || [ -z "$configured_weth_symbol" ]; then
        echo "Error: WETH_ADDRESS is zero; both WETH_NAME and WETH_SYMBOL are required in $network_dir/dex.params" >&2
        exit 1
    fi
fi

# The address file's key set must equal the expected contract set: a renamed key would leave later
# variables silently empty and fail much later with an unhelpful message, so assert it here.
address_file="$network_dir/addresses.weth.params"
expected_keys="WETH_ADDRESS"
actual_keys=$(grep -oE '^[A-Z0-9_]+=' "$address_file" | sed 's/=$//' | sort | tr '\n' ' ' || true)
if [ "$actual_keys" != "$(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" ]; then
    echo "Error: $address_file key set mismatch" >&2
    echo "  expected: $(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" >&2
    echo "  actual:   $actual_keys" >&2
    exit 1
fi

params_load "$network_dir/addresses.weth.params"
if [ "$configured_weth_external" -eq 1 ]; then
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
    echo "    contract: $address"
    echo "    call: $signature"
    echo "    actual: $actual"
    echo "    expected: $expected"
}

# External WETH mode verifies the address only; local deployment mode also verifies the configured
# name and symbol.
if [ "$configured_weth_external" -eq 1 ]; then
    echo "Skip WETH name/symbol (an external WETH is checked by address only)"
else
    check "WETH name" "$WETH_ADDRESS" "name()(string)" "\"$configured_weth_name\""
    check "WETH symbol" "$WETH_ADDRESS" "symbol()(string)" "\"$configured_weth_symbol\""
fi

weth_code=$(cast code "$WETH_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null) || true
if [[ ! "$weth_code" =~ ^0x[0-9a-fA-F]+$ ]]; then
    failed=$((failed + 1))
    echo "✗ WETH not deployed: $WETH_ADDRESS"
else
    echo "✓ WETH deployed"
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
    echo "✗ $failed check(s) failed" >&2
    exit 1
fi
echo "✓ WETH verified"
