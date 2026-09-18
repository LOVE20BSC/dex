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
[ -n "$RPC_URL" ] || fail "RPC_URL is not set"
[ -n "$WBNB_ADDRESS" ] || fail "WBNB_ADDRESS is not set"

if [ -f "$network_dir/.account" ]; then
    source "$network_dir/.account"
fi

if [ -n "${PRIVATE_KEY:-}" ]; then
    : "Using PRIVATE_KEY for this development network"
else
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
fi

export network network_dir DEX_ROOT WBNB="$WBNB_ADDRESS" WRITE_ADDRESS_FILE=true

forge_script() {
    cd "$DEX_ROOT" || return 1
    if [ -n "${PRIVATE_KEY:-}" ]; then
        forge script "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast --legacy
    else
        forge script "$@" --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT" \
            --sender "$ACCOUNT_ADDRESS" --password "$KEYSTORE_PASSWORD" --broadcast --legacy
    fi
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
echo "RPC_URL: $RPC_URL"
echo "WBNB_ADDRESS: $WBNB_ADDRESS"
