#!/usr/bin/env bash
set -euo pipefail

# Entrypoint: orchestration only. It sources no environment file itself - each step loads its own
# inputs, every step is invoked the same way (<step>.sh <network>), and steps never call each
# other nor depend on a preloaded environment.
# Module order is dependency order: deploy 1x / check 2x / verify 3x; the WETH module (11/21/31)
# comes first, the UniswapV2 module (12/22/32) after it.
# A new contract gets its own step scripts and one_click_deploy_<name>.sh; existing files stay
# untouched.
# Usage: script/deploy/one_click_deploy.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
network="${1:?usage: script/deploy/one_click_deploy.sh <network>}"

NETWORK_DIR="$DEX_ROOT/script/network/$network"
if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# The keystore password is resolved once per run: reset first (never inherit a value left over in
# the caller's environment, which would silently reuse the previous run's password), then read the
# password line from .account; if neither exists, prompt once and export it so every deployment step
# reuses it (the two deployment modules do not each prompt). A step run on its own still resolves it
# as environment -> .account -> prompt. The entrypoint only reads the password line and never
# sources the config file.
export KEYSTORE_PASSWORD=""
if [ ! -f "$NETWORK_DIR/.account" ]; then
    echo "Error: Missing required configuration: $NETWORK_DIR/.account"
    exit 1
fi
configured_password=$(grep -E '^KEYSTORE_PASSWORD=' "$NETWORK_DIR/.account" | tail -1 | cut -d= -f2- || true)
if [ -n "$configured_password" ]; then
    export KEYSTORE_PASSWORD="$configured_password"
fi
if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
    if ! command -v osascript >/dev/null 2>&1; then
        echo "Error: KEYSTORE_PASSWORD is empty and osascript is unavailable; set it in $NETWORK_DIR/.account for non-interactive use." >&2
        exit 1
    fi
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for deployment:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
    export KEYSTORE_PASSWORD
fi

# Deployment and checking are separate steps: a failed check must not overwrite the previously saved
# addresses. Back them up first, drop the backup once the check passes, restore it on failure.
BACKUP_DIR="$(mktemp -d)"
trap 'rm -rf "$BACKUP_DIR"' EXIT
for file in addresses.weth.params addresses.uniswapv2.params; do
    [ -f "$NETWORK_DIR/$file" ] && cp "$NETWORK_DIR/$file" "$BACKUP_DIR/$file"
    true
done

# Steps 1/2: deploy and initialize the contracts (each module loads its own deployment inputs). The
# address files are not written yet when this fails, so there is nothing to roll back.
bash "$SCRIPT_DIR/11_deploy_weth.sh" "$network"
bash "$SCRIPT_DIR/12_deploy_uniswapv2.sh" "$network"

# Steps 3/4: verify deployment and initialization (each module loads its own check inputs and
# restores the saved addresses on failure).
if ! bash "$SCRIPT_DIR/21_check_weth.sh" "$network" || ! bash "$SCRIPT_DIR/22_check_uniswapv2.sh" "$network"; then
    for file in addresses.weth.params addresses.uniswapv2.params; do
        if [ -f "$BACKUP_DIR/$file" ]; then
            cp "$BACKUP_DIR/$file" "$NETWORK_DIR/$file"
        else
            rm -f "$NETWORK_DIR/$file"
        fi
    done
    echo "Error: post-deployment check failed; the previously saved addresses were restored."
    exit 1
fi

# Steps 5/6: source verification (loads the address files itself). Each step skips itself when the
# chain has no verification; an external WETH is not verified (its owner maintains it), a locally
# deployed WETH goes through 31_verify_weth.sh.
bash "$SCRIPT_DIR/31_verify_weth.sh" "$network"
bash "$SCRIPT_DIR/32_verify.sh" "$network"

echo "✓ Deployment completed: $network"
