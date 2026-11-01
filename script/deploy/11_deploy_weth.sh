#!/usr/bin/env bash
set -euo pipefail

# Step 1 (WETH module): prepare WETH. Self-contained: loads and validates every file it needs,
# without relying on a preloaded caller environment.
# WETH_ADDRESS is a mandatory mode switch (zero address = deploy locally):
#   non-zero WETH_ADDRESS: reuse an externally deployed WETH; nothing is deployed and no
#   keystore is needed;
#   zero WETH_ADDRESS: WETH_NAME and WETH_SYMBOL are required and a configurable WETH is
#   deployed.
# A missing key or an empty value fails immediately instead of falling back to either branch -
# a forgotten external address must not silently become "deploy a local WETH".
# Deployment-time static checks (mutual exclusion, code presence, decimals/deposit/withdraw, local
# name/symbol) happen before broadcast in DeployWETH.s.sol; this step only orchestrates files,
# chain, account and password.
# Addresses are written to addresses.weth.params for the UniswapV2 module and the check steps.
# Usage: script/deploy/11_deploy_weth.sh <network>

network="${1:?usage: script/deploy/11_deploy_weth.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$DEX_ROOT/script/network/$network"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# An abnormal previous exit may leave a hidden address temp file behind; only this module's temp
# pattern is removed, never the real address file.
rm -f "$NETWORK_DIR/.addresses.weth.params."*

for config in network.params dex.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value. WETH_ADDRESS is the mode switch, and an empty value reads as
# neither "external" nor "local", so it is asserted against the file itself, never against the
# variable - an inherited value could satisfy that.
params_require_values "$NETWORK_DIR/dex.params" WETH_ADDRESS || exit 1

# WETH_NAME/WETH_SYMBOL only configure a local deployment and are read back through vm.envOr, so an
# inherited value would survive a profile that omits them and trip DeployWETH's mutual-exclusion
# check. params_unset_all only knows the keys the files still define, so clear these two explicitly
# before loading; a value the file does define is loaded again below.
unset WETH_NAME WETH_SYMBOL

params_unset_all "$NETWORK_DIR/network.params" "$NETWORK_DIR/dex.params"

params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/dex.params"

weth_address="${WETH_ADDRESS:-}"
zero_address=0x0000000000000000000000000000000000000000
if [ -z "$weth_address" ]; then
    echo "Error: WETH_ADDRESS must be set in $NETWORK_DIR/dex.params (use $zero_address to deploy locally)" >&2
    exit 1
fi
if [ "$(printf '%s' "$weth_address" | tr '[:upper:]' '[:lower:]')" = "$zero_address" ]; then
    weth_mode=local
    params_require_keys "$NETWORK_DIR/dex.params" WETH_NAME WETH_SYMBOL || exit 1
else
    weth_mode=external
fi

# The actual chain must match the configuration.
actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$actual_chain_id" = "$CHAIN_ID" ] || { echo "Error: chain ID mismatch: config=$CHAIN_ID rpc=$actual_chain_id" >&2; exit 1; }

ADDRESS_TMP="$NETWORK_DIR/.addresses.weth.params.$$"
export ADDRESSES_FILE="script/network/$network/.addresses.weth.params.$$"

echo "Network: $network (chain $CHAIN_ID)"
cd "$DEX_ROOT"

if [ "$weth_mode" = external ]; then
    # External WETH mode: run the Solidity script read-only for interface checks; no broadcast, no
    # keystore.
    trap 'rm -f "$ADDRESS_TMP"' EXIT
    echo "Using external WETH: $weth_address"
    if ! forge script script/deploy/DeployWETH.s.sol:DeployWETH --sig "run()" \
        --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" -vvv; then
        echo "Error: External WETH validation failed." >&2
        exit 1
    fi
else
    # Local deployment mode: .account and a password are only needed when broadcasting.
    if [ ! -f "$NETWORK_DIR/.account" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/.account" >&2
        exit 1
    fi

    env_password="${KEYSTORE_PASSWORD:-}"
    set -a
    source "$NETWORK_DIR/.account"
    set +a

    # An empty KEYSTORE_PASSWORD line in .account must not clear a password exported by the
    # entrypoint (that would prompt a second time).
    [ -n "${KEYSTORE_PASSWORD:-}" ] || KEYSTORE_PASSWORD="$env_password"

    [ -n "${KEYSTORE_ACCOUNT:-}" ] && [ -n "${ACCOUNT_ADDRESS:-}" ] \
        || { echo "Error: KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS is not set in $NETWORK_DIR/.account" >&2; exit 1; }

    if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
        if ! command -v osascript >/dev/null 2>&1; then
            echo "Error: KEYSTORE_PASSWORD is empty and osascript is unavailable; set it in $NETWORK_DIR/.account for non-interactive use." >&2
            exit 1
        fi
        KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for $KEYSTORE_ACCOUNT:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
    fi

    # The password goes to forge through a temp file because --password would put the plaintext into
    # the process arguments, readable by every local user. The trap is installed before the password
    # is written, so a failing chmod/printf leaks nothing.
    PASSWORD_FILE=$(mktemp)
    trap 'rm -f "$PASSWORD_FILE" "$ADDRESS_TMP"' EXIT
    chmod 600 "$PASSWORD_FILE"
    printf '%s' "$KEYSTORE_PASSWORD" > "$PASSWORD_FILE"

    DEPLOY_START_EPOCH_SECONDS=$(date +%s)
    echo "Deploying WETH to $network..."
    if ! forge script script/deploy/DeployWETH.s.sol:DeployWETH --sig "run()" \
        --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
        --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" \
        --password-file "$PASSWORD_FILE" --broadcast --legacy -vvv; then
        echo "Error: WETH deployment failed." >&2
        exit 1
    fi
    rm -f "$PASSWORD_FILE"

    BROADCAST_FILE="$DEX_ROOT/broadcast/DeployWETH.s.sol/$CHAIN_ID/run-latest.json"
    if [ ! -f "$BROADCAST_FILE" ]; then
        echo "Error: Missing broadcast artifact: $BROADCAST_FILE" >&2
        exit 1
    fi
    BROADCAST_TIMESTAMP_MS=$(sed -nE 's/.*"timestamp":[[:space:]]*([0-9]+).*/\1/p' "$BROADCAST_FILE" | tail -1)
    if [ -z "$BROADCAST_TIMESTAMP_MS" ] || [ "$BROADCAST_TIMESTAMP_MS" -lt "$((DEPLOY_START_EPOCH_SECONDS * 1000))" ]; then
        echo "Error: Broadcast artifact was not updated by this deployment: $BROADCAST_FILE" >&2
        exit 1
    fi
fi

if [ ! -f "$ADDRESS_TMP" ]; then
    echo "Error: DeployWETH.s.sol did not write $ADDRESS_TMP" >&2
    exit 1
fi
deployed_weth=$(sed -nE 's/^WETH_ADDRESS=(.*)$/\1/p' "$ADDRESS_TMP" | tail -1 | xargs || true)
if [[ ! "$deployed_weth" =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ "$deployed_weth" = 0x0000000000000000000000000000000000000000 ]]; then
    echo "Error: Invalid WETH_ADDRESS in $ADDRESS_TMP" >&2
    exit 1
fi
printf 'WETH_ADDRESS=%s\n' "$deployed_weth" > "$ADDRESS_TMP"
mv "$ADDRESS_TMP" "$NETWORK_DIR/addresses.weth.params"

echo "✓ WETH: $deployed_weth"
