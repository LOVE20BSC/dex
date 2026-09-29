#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() { echo -e "\033[31mError:\033[0m $*"; return 1 2>/dev/null || exit 1; }

network="${1:-}"
[ -n "$network" ] || fail "Network parameter is required."
network_dir="$SCRIPT_DIR/../network/$network"
[ -d "$network_dir" ] || fail "Unknown network: $network"
[ -f "$network_dir/network.params" ] || fail "Missing $network_dir/network.params"

source "$network_dir/network.params"
[ -n "$CHAIN_ID" ] || fail "CHAIN_ID is not set"
[ -n "$RPC_URL" ] || fail "RPC_URL is not set"
actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null)" || fail "Cannot read Chain ID from RPC_URL"
[ "$actual_chain_id" = "$CHAIN_ID" ] || fail "Chain ID mismatch: config=$CHAIN_ID rpc=$actual_chain_id"

[ -f "$network_dir/dex.params" ] || fail "Missing $network_dir/dex.params"
source "$network_dir/dex.params"
[ "${DEPLOY_TEST_WBNB:-false}" = "true" ] || [ -n "$WBNB_ADDRESS" ] || fail "WBNB_ADDRESS is not set"

source "$network_dir/.account" 2>/dev/null || fail "Missing $network_dir/.account"
[ -n "${KEYSTORE_ACCOUNT:-}" ] || fail "KEYSTORE_ACCOUNT is not set in $network_dir/.account"
[ -n "${ACCOUNT_ADDRESS:-}" ] || fail "ACCOUNT_ADDRESS is not set in $network_dir/.account"
if [ -z "${KEYSTORE_PASSWORD:-}" ] || [ "${KEYSTORE_PASSWORD_ACCOUNT:-}" != "$KEYSTORE_ACCOUNT" ]; then
    unset KEYSTORE_PASSWORD KEYSTORE_PASSWORD_ACCOUNT
    command -v osascript >/dev/null 2>&1 || fail "osascript is required for the keystore password dialog"
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for $KEYSTORE_ACCOUNT:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)" || fail "Keystore password input cancelled"
    [ -n "$KEYSTORE_PASSWORD" ] || fail "Keystore password input cancelled"
    export KEYSTORE_PASSWORD KEYSTORE_PASSWORD_ACCOUNT="$KEYSTORE_ACCOUNT"
fi

export network network_dir DEX_ROOT CHAIN_ID RPC_URL DEPLOY_TEST_WBNB WBNB="${WBNB_ADDRESS:-}" WRITE_ADDRESS_FILE=true

forge_script() {
    cd "$DEX_ROOT" || return 1
    forge script "$@" --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT" \
        --sender "$ACCOUNT_ADDRESS" --password "$KEYSTORE_PASSWORD" --broadcast --legacy
}

cast_call() {
    cast call "$1" "$2" --rpc-url "$RPC_URL"
}

check_equal() {
    local description="$1" expected="$2" actual="$3"
    expected="$(echo "$expected" | tr '[:upper:]' '[:lower:]')"
    actual="$(echo "$actual" | tr '[:upper:]' '[:lower:]')"
    [ "$expected" = "$actual" ] || { echo "✗ $description: got $actual, want $expected"; return 1; }
    echo "✓ $description: $actual"
}

echo "Selected network: $network"
echo "Chain ID: $CHAIN_ID"
echo "RPC_URL: $RPC_URL"
if [ "${DEPLOY_TEST_WBNB:-false}" = "true" ]; then
    echo "WBNB: deploy TestWBNB from upstream WETH9"
else
    echo "WBNB_ADDRESS: $WBNB_ADDRESS"
fi
