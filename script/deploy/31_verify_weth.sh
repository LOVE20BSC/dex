#!/usr/bin/env bash
set -euo pipefail

# Step 3 (WETH module): source verification of the locally deployed WETH. Self-contained: loads
# network.params, verifier.params, dex.params and addresses.weth.params. An external WETH is
# maintained by its owner and not verified here; the step returns success when the chain is listed
# in VERIFY_SKIP_CHAIN_IDS.
# Usage: script/deploy/31_verify_weth.sh <network>

network="${1:?usage: script/deploy/31_verify_weth.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEX_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$DEX_ROOT/script/network/$network"
VERIFIER_PARAMS="$DEX_ROOT/script/network/verifier.params"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params dex.params addresses.weth.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done
if [ ! -f "$VERIFIER_PARAMS" ]; then
    echo "Error: Missing required configuration: $VERIFIER_PARAMS"
    exit 1
fi

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value. WETH_ADDRESS is the mode switch, and an empty value reads as
# neither "external" nor "local", so it is asserted against the file itself, never against the
# variable - an inherited value could satisfy that.
params_require_values "$NETWORK_DIR/dex.params" WETH_ADDRESS || exit 1

# WETH_NAME/WETH_SYMBOL only configure a local deployment; clear any inherited value before loading
# so an external-mode profile cannot pass a stale name/symbol into the constructor arguments.
unset WETH_NAME WETH_SYMBOL

params_unset_all "$NETWORK_DIR/network.params" "$VERIFIER_PARAMS" \
    "$NETWORK_DIR/dex.params" "$NETWORK_DIR/addresses.weth.params"

params_load "$NETWORK_DIR/network.params"
params_load "$VERIFIER_PARAMS"
params_load "$NETWORK_DIR/dex.params"
configured_weth_address="${WETH_ADDRESS:-}"
params_load "$NETWORK_DIR/addresses.weth.params"
zero_address=0x0000000000000000000000000000000000000000

cd "$DEX_ROOT"

# The opt-out list is mandatory as a key but may be empty: "verify every chain" is a legal answer.
params_require_keys "$VERIFIER_PARAMS" VERIFY_SKIP_CHAIN_IDS || exit 1

# Verification is attempted by default: only the chains listed here skip it, so a new production
# chain fails loudly instead of passing unverified.
skip_chains=",${VERIFY_SKIP_CHAIN_IDS:-},"
if [ -n "${CHAIN_ID:-}" ] && [[ "$skip_chains" == *",$CHAIN_ID,"* ]]; then
    echo "Skip: source verification is disabled for chain $CHAIN_ID in $VERIFIER_PARAMS"
    exit 0
fi

# The endpoint is a mandatory key: an empty URL would be passed straight to forge.
params_require_values "$VERIFIER_PARAMS" ETHERSCAN_VERIFIER_URL || exit 1

# WETH_ADDRESS is a mandatory mode switch (zero address = deploy locally); a missing key or an empty
# value fails instead of continuing in either mode.
if [ -z "$configured_weth_address" ]; then
    echo "Error: WETH_ADDRESS must be set in $NETWORK_DIR/dex.params (use $zero_address to deploy locally)" >&2
    exit 1
fi
if [ "$(printf '%s' "$configured_weth_address" | tr '[:upper:]' '[:lower:]')" != "$zero_address" ]; then
    echo "Skip: external WETH is verified by its own deployment, not this repository"
    exit 0
fi

params_require_keys "$NETWORK_DIR/dex.params" WETH_NAME WETH_SYMBOL || exit 1
if [ -z "${WETH_NAME:-}" ] || [ -z "${WETH_SYMBOL:-}" ]; then
    echo "Error: local WETH deployment is missing WETH_NAME / WETH_SYMBOL in $NETWORK_DIR/dex.params" >&2
    exit 1
fi
if [[ ! "$WETH_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ "$WETH_ADDRESS" = 0x0000000000000000000000000000000000000000 ]]; then
    echo "Error: Missing or invalid WETH_ADDRESS in $NETWORK_DIR/addresses.weth.params" >&2
    exit 1
fi
unset ETHERSCAN_API_KEY
if [ ! -f "$NETWORK_DIR/.account" ]; then
    echo "Error: Missing required configuration: $NETWORK_DIR/.account" >&2
    exit 1
fi
set -a
source "$NETWORK_DIR/.account"
set +a
: "${ETHERSCAN_API_KEY:?Set ETHERSCAN_API_KEY in .account; source verification has not run.}"

if ! WETH_ARGS=$(cast abi-encode "constructor(string,string)" "$WETH_NAME" "$WETH_SYMBOL"); then
    echo "Error: Failed to encode WETH9Configurable constructor arguments" >&2
    exit 1
fi

forge verify-contract "$WETH_ADDRESS" "script/WETH9Configurable.sol:WETH9Configurable" \
    --chain "$CHAIN_ID" --verifier etherscan --verifier-url "$ETHERSCAN_VERIFIER_URL" \
    --constructor-args "$WETH_ARGS" --watch
echo "✓ Source verification succeeded for WETH"
