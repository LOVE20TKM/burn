#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_ROOT="$(cd "$SCRIPT_DIR/../network" && pwd)"
network=${1:-}
network_dir="$NETWORK_ROOT/$network"

if [ -z "$network" ] || [ ! -d "$network_dir" ]; then
    echo "Error: network parameter is required" >&2
    exit 1
fi
if [ ! -f "$network_dir/network.params" ] || [ ! -f "$network_dir/burn.params" ]; then
    echo "Error: network.params or burn.params not found" >&2
    exit 1
fi

source "$network_dir/network.params"
source "$network_dir/burn.params"

if [ -z "${RPC_URL:-}" ] || [ -z "${CHAIN_ID:-}" ] || [ -z "${EXTENSION_CENTER:-}" ]; then
    echo "Error: RPC_URL, CHAIN_ID and EXTENSION_CENTER are required" >&2
    exit 1
fi

actual_chain_id=$(cast chain-id --rpc-url "$RPC_URL")
if [ "$actual_chain_id" != "$CHAIN_ID" ]; then
    echo "Error: chain id mismatch (expected $CHAIN_ID, actual $actual_chain_id)" >&2
    exit 1
fi

call() {
    local address=$1
    local signature=$2
    shift 2
    cast call "$address" "$signature" "$@" --rpc-url "$RPC_URL"
}

launch_address=$(call "$EXTENSION_CENTER" "launchAddress()(address)")
launched_count=$(call "$launch_address" "launchedTokensCount()(uint256)")
launched_count=${launched_count%% *}
if [ "$launched_count" -eq 0 ]; then
    echo "Error: Launch has no completed tokens" >&2
    exit 1
fi

scope_token=$(call "$launch_address" "launchedTokensAtIndex(uint256)(address)" 0)
scope_token_lower=$(printf '%s' "$scope_token" | tr '[:upper:]' '[:lower:]')
community_symbols=
community_weights=
scope_symbol=

printf 'Launch: %s\n' "$launch_address"
printf 'Completed tokens: %s\n\n' "$launched_count"
printf '%-8s %-12s %-42s %s\n' TYPE SYMBOL TOKEN FIRST_TOKEN_AMOUNT

for ((i = 0; i < launched_count; i++)); do
    token=$(call "$launch_address" "launchedTokensAtIndex(uint256)(address)" "$i")
    token_lower=$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')
    symbol=$(call "$token" "symbol()(string)")
    symbol=${symbol#\"}
    symbol=${symbol%\"}
    parent_token=$(call "$token" "parentTokenAddress()(address)")
    parent_token_lower=$(printf '%s' "$parent_token" | tr '[:upper:]' '[:lower:]')

    if [ "$token_lower" = "$scope_token_lower" ]; then
        type=scope
        amount_line=1
        scope_symbol=$symbol
    elif [ "$parent_token_lower" = "$scope_token_lower" ]; then
        type=child
        amount_line=2
    else
        printf '%-8s %-12s %-42s %s\n' skipped "$symbol" "$token" "not a direct child"
        continue
    fi

    sl_address=$(call "$token" "slAddress()(address)")
    amounts=$(call "$sl_address" "tokenAmounts()(uint256,uint256,uint256,uint256)")
    weight=$(printf '%s\n' "$amounts" | sed -n "${amount_line}p" | awk '{print $1}')
    if [[ ! "$weight" =~ ^[0-9]+$ ]]; then
        echo "Error: invalid SL token amount for $token" >&2
        exit 1
    fi
    if [[ "$weight" =~ ^0+$ ]]; then
        if [ "$type" = scope ]; then
            echo "Error: scope token has zero first-token liquidity stake" >&2
            exit 1
        fi
        printf '%-8s %-12s %-42s %s\n' skipped "$symbol" "$token" "zero"
        continue
    fi

    printf '%-8s %-12s %-42s %s\n' "$type" "$symbol" "$token" "$weight"
    community_symbols="${community_symbols:+$community_symbols,}$symbol"
    community_weights="${community_weights:+$community_weights,}$weight"
done

printf '\nReview, then update burn.params manually:\n'
printf 'SCOPE_TOKEN_SYMBOL=%s\n' "$scope_symbol"
printf 'COMMUNITY_SYMBOLS=%s\n' "$community_symbols"
printf 'COMMUNITY_WEIGHTS=%s\n' "$community_weights"
printf 'CATEGORY_WEIGHTS=1:1:1:1\n'
