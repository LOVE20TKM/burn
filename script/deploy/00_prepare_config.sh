#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_ROOT="$(cd "$SCRIPT_DIR/../network" && pwd)"
network=${1:-}
mode=${2:-}
network_dir="$NETWORK_ROOT/$network"

if [ -z "$network" ] || [ ! -d "$network_dir" ]; then
    echo "Error: network parameter is required" >&2
    exit 1
fi
if [ -n "$mode" ] && [ "$mode" != "--check" ]; then
    echo "Error: optional second parameter must be --check" >&2
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

source_block=$(cast block-number --rpc-url "$RPC_URL")
source_block=${source_block%% *}
source_block_hash=$(cast block "$source_block" --field hash --rpc-url "$RPC_URL")
if [[ ! "$source_block" =~ ^[0-9]+$ ]] || [[ ! "$source_block_hash" =~ ^0x[[:xdigit:]]{64}$ ]]; then
    echo "Error: invalid source block metadata" >&2
    exit 1
fi

call() {
    local address=$1
    local signature=$2
    shift 2
    cast call "$address" "$signature" "$@" --rpc-url "$RPC_URL" --block "$source_block"
}

launch_address=$(call "$EXTENSION_CENTER" "launchAddress()(address)")
launched_count=$(call "$launch_address" "launchedTokensCount()(uint256)")
launched_count=${launched_count%% *}
if [ "$launched_count" -eq 0 ]; then
    echo "Error: Launch has no completed tokens" >&2
    exit 1
fi

if [ -n "${SCOPE_TOKEN_SYMBOL:-}" ]; then
    scope_token=$(call "$launch_address" "tokenAddressBySymbol(string)(address)" "$SCOPE_TOKEN_SYMBOL")
else
    scope_token=$(call "$launch_address" "launchedTokensAtIndex(uint256)(address)" 0)
fi
if [ "$scope_token" = "0x0000000000000000000000000000000000000000" ]; then
    echo "Error: scope token not found" >&2
    exit 1
fi
scope_token_lower=$(printf '%s' "$scope_token" | tr '[:upper:]' '[:lower:]')
community_symbols=
community_weights=
scope_symbol=
snapshot_comments=

printf 'Launch: %s\n' "$launch_address"
printf 'Source block: %s (%s)\n' "$source_block" "$source_block_hash"
printf 'Completed tokens: %s\n\n' "$launched_count"
printf '%-8s %-12s %-42s %s\n' TYPE SYMBOL TOKEN SL_LOVE20_AMOUNT

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
    amount_field=withdrawableParentTokenAmount
    [ "$type" = scope ] && amount_field=withdrawableTokenAmount
    snapshot_comments="${snapshot_comments}# symbol=$symbol token=$token slToken=$sl_address amountField=$amount_field love20Amount=$weight
"
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

if [ -z "$scope_symbol" ]; then
    echo "Error: scope token is not in Launch's completed token list" >&2
    exit 1
fi

if [ "$mode" = "--check" ]; then
    print_changes() {
        local expected_symbols= expected_weights= current_symbols= current_weights=
        local expected_count current_count expected_weights_count current_weights_count count i
        IFS=, read -r -a expected_symbols <<< "${COMMUNITY_SYMBOLS:-}"
        IFS=, read -r -a expected_weights <<< "${COMMUNITY_WEIGHTS:-}"
        IFS=, read -r -a current_symbols <<< "$community_symbols"
        IFS=, read -r -a current_weights <<< "$community_weights"
        expected_count=${#expected_symbols[@]}
        current_count=${#current_symbols[@]}
        expected_weights_count=${#expected_weights[@]}
        current_weights_count=${#current_weights[@]}
        count=$expected_count
        [ "$current_count" -lt "$count" ] && count=$current_count
        [ "$expected_weights_count" -lt "$count" ] && count=$expected_weights_count
        [ "$current_weights_count" -lt "$count" ] && count=$current_weights_count
        printf '\nCommunity LOVE20 amount changes (chain vs params):\n'
        for ((i = 0; i < count; ++i)); do
            awk -v symbol="${current_symbols[i]}" -v expected="${expected_weights[i]}" -v current="${current_weights[i]}" '
                BEGIN {
                    if (expected == 0) {
                        change = current == 0 ? "0.00000000%" : "N/A (params=0)"
                    } else {
                        change = sprintf("%+.8f%%", (current - expected) * 100 / expected)
                    }
                    printf "  %s: params=%s chain=%s change=%s\n", symbol, expected, current, change
                }
            '
        done
    }
    print_changes
    if [ "${SCOPE_TOKEN_SYMBOL:-}" != "$scope_symbol" ]; then
        echo "Error: SCOPE_TOKEN_SYMBOL mismatch (params=${SCOPE_TOKEN_SYMBOL:-<empty>}, chain=$scope_symbol)" >&2
        exit 1
    fi
    if [ "${COMMUNITY_SYMBOLS:-}" != "$community_symbols" ]; then
        echo "Error: COMMUNITY_SYMBOLS mismatch (params=${COMMUNITY_SYMBOLS:-<empty>}, chain=$community_symbols)" >&2
        exit 1
    fi
    if [ "${COMMUNITY_WEIGHTS:-}" != "$community_weights" ]; then
        echo "Error: COMMUNITY_WEIGHTS mismatch (params=${COMMUNITY_WEIGHTS:-<empty>}, chain=$community_weights)" >&2
        exit 1
    fi
    printf '\nDeployment community parameters match the sampled block.\n'
elif [ -z "$mode" ]; then
    begin='# BEGIN AUTO-GENERATED COMMUNITY SL SNAPSHOT'
    end='# END AUTO-GENERATED COMMUNITY SL SNAPSHOT'
    if ! awk -v begin="$begin" -v end="$end" '
        $0 == begin { ++begins; invalid = invalid || inside; inside = 1 }
        $0 == end { ++ends; invalid = invalid || !inside; inside = 0 }
        END {
            if (inside || invalid || begins > 1 || ends > 1 || begins != ends) exit 1
        }
    ' "$network_dir/burn.params"; then
        echo "Error: malformed community snapshot markers in $network_dir/burn.params" >&2
        exit 1
    fi
    output=$(mktemp "${TMPDIR:-/tmp}/burn.params.XXXXXX")
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { skipping = 1; next }
        $0 == end { skipping = 0; next }
        !skipping { print }
    ' "$network_dir/burn.params" >"$output"
    printf '\n%s\n' "$begin" >>"$output"
    printf '# sourceBlock=%s\n' "$source_block" >>"$output"
    printf '# sourceBlockHash=%s\n' "$source_block_hash" >>"$output"
    printf '# scopeTokenSymbol=%s\n' "$scope_symbol" >>"$output"
    printf '# amountRule=scope withdrawableTokenAmount; direct child withdrawableParentTokenAmount\n' >>"$output"
    printf '%s' "$snapshot_comments" >>"$output"
    printf '%s\n' "$end" >>"$output"
    cp "$output" "$network_dir/burn.params"
    rm -f "$output"
    printf '\nUpdated comments in %s\n' "$network_dir/burn.params"
fi

printf '\nReview, then update deployment variables manually:\n'
printf 'SCOPE_TOKEN_SYMBOL=%s\n' "$scope_symbol"
printf 'COMMUNITY_SYMBOLS=%s\n' "$community_symbols"
printf 'COMMUNITY_WEIGHTS=%s\n' "$community_weights"
printf 'SL_TOKEN_LOCK_WEIGHT=1\n'
printf 'ST_TOKEN_LOCK_WEIGHT=1\n'
printf 'GOV_REWARD_BURN_WEIGHT=1\n'
printf 'ACTION_REWARD_BURN_WEIGHT=1\n'
