#!/usr/bin/env bash
set -euo pipefail

# Step 3 (UniswapV2 module): source verification. Self-contained: loads network.params,
# verifier.params and both modules' address files (WETH_ADDRESS from addresses.weth.params), without
# relying on the entrypoint to refresh addresses.
# WETH is not verified here: an external WETH is maintained by its owner and a locally
# deployed one is verified by 31_verify_weth.sh.
# Usage: script/deploy/32_verify.sh <network>

network="${1:?usage: script/deploy/32_verify.sh <network>}"

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

for config in network.params addresses.weth.params addresses.uniswapv2.params; do
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
# caller cannot override a file value.
params_unset_all "$NETWORK_DIR/network.params" "$VERIFIER_PARAMS" \
    "$NETWORK_DIR/addresses.weth.params" "$NETWORK_DIR/addresses.uniswapv2.params"

params_load "$NETWORK_DIR/network.params"
params_load "$VERIFIER_PARAMS"
params_load "$NETWORK_DIR/addresses.weth.params"
params_load "$NETWORK_DIR/addresses.uniswapv2.params"

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
unset ETHERSCAN_API_KEY
if [ ! -f "$NETWORK_DIR/.account" ]; then
    echo "Error: Missing required configuration: $NETWORK_DIR/.account" >&2
    exit 1
fi
set -a
source "$NETWORK_DIR/.account"
set +a
: "${ETHERSCAN_API_KEY:?Set ETHERSCAN_API_KEY in .account; source verification has not run.}"

# Verify each address field against its module file: WETH from the WETH module file, Factory/Router
# from the UniswapV2 module file.
for field in WETH_ADDRESS; do
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Missing or invalid $field in $NETWORK_DIR/addresses.weth.params"
        exit 1
    fi
done
for field in FACTORY_ADDRESS ROUTER_ADDRESS; do
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Missing or invalid $field in $NETWORK_DIR/addresses.uniswapv2.params"
        exit 1
    fi
done

# The Factory fixes feeToSetter to address(0) (protocol fee permanently waived, see docs/adr/0001);
# Router02 binds this deployment's Factory and WETH. A failing command substitution would silently
# abort under set -e, so each call is checked explicitly for a clear message.
if ! FACTORY_ARGS=$(cast abi-encode "constructor(address)" 0x0000000000000000000000000000000000000000); then
    echo "Error: Failed to encode Factory constructor arguments"
    exit 1
fi
if ! ROUTER_ARGS=$(cast abi-encode "constructor(address,address)" "$FACTORY_ADDRESS" "$WETH_ADDRESS"); then
    echo "Error: Failed to encode Router02 constructor arguments"
    exit 1
fi

COMMON_ARGS=(--chain "$CHAIN_ID" --verifier etherscan --verifier-url "$ETHERSCAN_VERIFIER_URL" --watch)
verify_contract() {
    local address=$1 source=$2 name=$3
    shift 3
    echo "Verifying $name..."
    forge verify-contract "$address" "$source:$name" "${COMMON_ARGS[@]}" "$@"
}

# Only the two contracts deployed by this repository are verified. WETH is not verified here: on
# public chains it is the official pre-existing contract (WBNB on BSC) built with different compiler
# settings, so submitting local sources always fails; on local chains (WETH_ADDRESS = zero address)
# WETH9 is skipped together with the whole chain, so there is nothing to verify.
verify_contract "$FACTORY_ADDRESS" lib/v2-core/contracts/UniswapV2Factory.sol UniswapV2Factory --constructor-args "$FACTORY_ARGS"
verify_contract "$ROUTER_ADDRESS" lib/v2-periphery/contracts/UniswapV2Router02.sol UniswapV2Router02 --constructor-args "$ROUTER_ARGS"
echo "✓ Source verification succeeded for Factory and Router02"
