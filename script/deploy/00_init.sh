#!/bin/bash

if [ -n "${ZSH_VERSION:-}" ]; then
    SCRIPT_PATH="$0"
elif [ -n "${BASH_VERSION:-}" ]; then
    SCRIPT_PATH="${BASH_SOURCE[0]}"
else
    SCRIPT_PATH="$0"
fi

SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
NETWORK_ROOT="$(cd "$SCRIPT_DIR/../network" && pwd)"

export network=$1
if [ -z "$network" ] || [ ! -d "$NETWORK_ROOT/$network" ]; then
    echo -e "\033[31mError:\033[0m Network parameter is required."
    echo -e "\nAvailable networks:"
    for net in "$NETWORK_ROOT"/*; do
        [ -d "$net" ] && echo "  - $(basename "$net")"
    done
    return 1 2>/dev/null || exit 1
fi

export network_dir="$NETWORK_ROOT/$network"

if [ ! -f "$network_dir/.account" ]; then
    echo -e "\033[31mError:\033[0m .account file not found"
    echo "Create $network_dir/.account from .account.example"
    return 1 2>/dev/null || exit 1
fi

if [ ! -f "$network_dir/network.params" ] || [ ! -f "$network_dir/burn.params" ]; then
    echo -e "\033[31mError:\033[0m network.params or burn.params not found"
    return 1 2>/dev/null || exit 1
fi

unset EXTENSION_CENTER SCOPE_TOKEN_SYMBOL AIRDROP_TOKEN COMMUNITY_SYMBOLS COMMUNITY_WEIGHTS
unset SCOPE_TOKEN COMMUNITY_TOKENS
unset START_ROUND ROUND_COUNT QUOTA_MULTIPLIER SUPPORTED_EXTENSION_FACTORIES

set -a
source "$network_dir/.account"
source "$network_dir/network.params"
source "$network_dir/burn.params"
set +a

actual_chain_id=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null)
if [ -z "$RPC_URL" ] || [ -z "$CHAIN_ID" ] || [ "$actual_chain_id" != "$CHAIN_ID" ]; then
    echo -e "\033[31mError:\033[0m RPC unavailable or chain id mismatch"
    return 1 2>/dev/null || exit 1
fi

for name in EXTENSION_CENTER SCOPE_TOKEN_SYMBOL COMMUNITY_SYMBOLS COMMUNITY_WEIGHTS START_ROUND ROUND_COUNT QUOTA_MULTIPLIER; do
    if [ -z "$(printenv "$name")" ]; then
        echo -e "\033[31mError:\033[0m $name is required in burn.params"
        return 1 2>/dev/null || exit 1
    fi
done

if [[ ! "$START_ROUND" =~ ^[0-9]+$ ]]; then
    echo -e "\033[31mError:\033[0m START_ROUND must be an explicit non-negative integer"
    return 1 2>/dev/null || exit 1
fi

symbol_count=$(printf '%s' "$COMMUNITY_SYMBOLS" | awk -F, '{print NF}')
weight_count=$(printf '%s' "$COMMUNITY_WEIGHTS" | awk -F, '{print NF}')
if [ "$symbol_count" != "$weight_count" ]; then
    echo -e "\033[31mError:\033[0m COMMUNITY_SYMBOLS and COMMUNITY_WEIGHTS length mismatch"
    return 1 2>/dev/null || exit 1
fi

cast_call() {
    local address=$1
    local signature=$2
    shift 2
    cast call "$address" "$signature" "$@" --rpc-url "$RPC_URL"
}

launch_address=$(cast_call "$EXTENSION_CENTER" "launchAddress()(address)") \
    || return 1 2>/dev/null || exit 1

resolve_community_symbol() {
    local symbol=$1
    local token
    local is_love20_token
    token=$(cast_call "$launch_address" "tokenAddressBySymbol(string)(address)" "$symbol") || return 1
    is_love20_token=$(cast_call "$launch_address" "isLOVE20Token(address)(bool)" "$token") || return 1
    if [ "$token" = "0x0000000000000000000000000000000000000000" ] || [ "$is_love20_token" != "true" ]; then
        echo -e "\033[31mError:\033[0m $symbol is not a token issued by Launch" >&2
        return 1
    fi
    printf '%s' "$token"
}

SCOPE_TOKEN=$(resolve_community_symbol "$SCOPE_TOKEN_SYMBOL") \
    || return 1 2>/dev/null || exit 1
COMMUNITY_TOKENS=
symbols="$COMMUNITY_SYMBOLS,"
while [ -n "$symbols" ]; do
    symbol="${symbols%%,*}"
    symbols="${symbols#*,}"
    token=$(resolve_community_symbol "$symbol") || return 1 2>/dev/null || exit 1
    COMMUNITY_TOKENS="${COMMUNITY_TOKENS:+$COMMUNITY_TOKENS,}$token"
done
export SCOPE_TOKEN COMMUNITY_TOKENS

request_keystore_password() {
    if [ -n "$KEYSTORE_PASSWORD" ] && [ "$KEYSTORE_PASSWORD_ACCOUNT" = "$KEYSTORE_ACCOUNT" ]; then
        return 0
    fi

    unset KEYSTORE_PASSWORD KEYSTORE_PASSWORD_ACCOUNT
    local escaped_account
    escaped_account=$(printf '%s' "$KEYSTORE_ACCOUNT" | sed 's/\\/\\\\/g; s/"/\\"/g')

    KEYSTORE_PASSWORD="$(osascript -l JavaScript <<JAVASCRIPT
const app = Application.currentApplication();
app.includeStandardAdditions = true;
app.displayDialog("Enter keystore password for $escaped_account:", {
    defaultAnswer: "",
    hiddenAnswer: true,
    buttons: ["Cancel", "OK"],
    defaultButton: "OK",
}).textReturned;
JAVASCRIPT
)"

    if [ $? -ne 0 ] || [ -z "$KEYSTORE_PASSWORD" ]; then
        echo -e "\033[31mError:\033[0m Keystore password input cancelled"
        return 1
    fi

    export KEYSTORE_PASSWORD KEYSTORE_PASSWORD_ACCOUNT="$KEYSTORE_ACCOUNT"
}

if [ "$network" = "anvil" ]; then
    if [ -z "$PRIVATE_KEY" ]; then
        echo -e "\033[31mError:\033[0m PRIVATE_KEY is required for anvil deployment"
        return 1 2>/dev/null || exit 1
    fi
else
    request_keystore_password || return 1 2>/dev/null || exit 1
fi

normalize_value() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^([0-9]+)[[:space:]]+\[[^]]+\]$/\1/'
}

check_equal() {
    local description=$1
    local expected
    local actual
    expected=$(normalize_value "$2")
    actual=$(normalize_value "$3")
    if [ "$expected" = "$actual" ]; then
        echo -e "\033[32m✓\033[0m $description"
        return 0
    fi
    echo -e "\033[31m✗\033[0m $description (expected $expected, actual $actual)"
    return 1
}

forge_script() {
    if [ "$network" = "anvil" ]; then
        local anvil_build_args=()
        [ -n "$ANVIL_FOUNDRY_OUT" ] && anvil_build_args+=(--out "$ANVIL_FOUNDRY_OUT")
        [ -n "$ANVIL_FOUNDRY_CACHE" ] && anvil_build_args+=(--cache-path "$ANVIL_FOUNDRY_CACHE")
        forge script "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --sender "$ACCOUNT_ADDRESS" \
            --gas-price 5000000000 --gas-limit 50000000 --broadcast --legacy "${anvil_build_args[@]}"
    else
        forge script "$@" --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" \
            --password "$KEYSTORE_PASSWORD" --gas-price 5000000000 --gas-limit 50000000 --broadcast --legacy
    fi
}
