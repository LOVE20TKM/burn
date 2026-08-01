#!/usr/bin/env bash

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCOUNT_FILE="$REPO_ROOT/script/network/anvil/.account"
created_account=false
failures=0

cleanup() {
    if [ "$created_account" = true ]; then
        rm -f "$ACCOUNT_FILE"
    fi
}
trap cleanup EXIT

if [ ! -f "$ACCOUNT_FILE" ]; then
    printf '%s\n' \
        'PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' \
        'ACCOUNT_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' >"$ACCOUNT_FILE"
    created_account=true
fi

assert_fails_with() {
    local name=$1
    local expected=$2
    shift 2
    local output
    local status

    output=$("$@" 2>&1)
    status=$?
    if [ "$status" -eq 0 ] || [[ "$output" != *"$expected"* ]]; then
        printf 'not ok - %s (status=%s, output=%s)\n' "$name" "$status" "$output"
        failures=$((failures + 1))
        return
    fi
    printf 'ok - %s\n' "$name"
}

assert_succeeds() {
    local name=$1
    shift
    local output
    local status

    output=$("$@" 2>&1)
    status=$?
    if [ "$status" -ne 0 ]; then
        printf 'not ok - %s (status=%s, output=%s)\n' "$name" "$status" "$output"
        failures=$((failures + 1))
        return
    fi
    printf 'ok - %s\n' "$name"
}

invalid_start_round() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local network_name="invalid_start_round_$$"
    local network_path="$REPO_ROOT/script/network/$network_name"
    mkdir -p "$network_path"
    trap 'rm -rf "$network_path"' EXIT
    : >"$network_path/.account"
    printf '%s\n' \
        'RPC_URL=http://127.0.0.1:8545' \
        'CHAIN_ID=31337' >"$network_path/network.params"
    printf '%s\n' \
        'EXTENSION_CENTER=0x1111111111111111111111111111111111111111' \
        'SCOPE_TOKEN_SYMBOL=FIRST' \
        'COMMUNITY_SYMBOLS=FIRST' \
        'COMMUNITY_WEIGHTS=1' \
        'CATEGORY_WEIGHTS=1:1:1:1' \
        'START_ROUND=current' \
        'ROUND_COUNT=3' \
        'QUOTA_MULTIPLIER=5' >"$network_path/burn.params"
    cast() {
        if [ "$1" = "chain-id" ]; then
            printf '31337\n'
            return 0
        fi
        return 1
    }
    source script/deploy/00_init.sh "$network_name"
)

invalid_category_weights() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local network_name="invalid_category_weights_$$"
    local network_path="$REPO_ROOT/script/network/$network_name"
    mkdir -p "$network_path"
    trap 'rm -rf "$network_path"' EXIT
    : >"$network_path/.account"
    printf '%s\n' \
        'RPC_URL=http://127.0.0.1:8545' \
        'CHAIN_ID=31337' >"$network_path/network.params"
    printf '%s\n' \
        'EXTENSION_CENTER=0x1111111111111111111111111111111111111111' \
        'SCOPE_TOKEN_SYMBOL=FIRST' \
        'COMMUNITY_SYMBOLS=FIRST' \
        'COMMUNITY_WEIGHTS=1' \
        'CATEGORY_WEIGHTS=1:1:1' \
        'START_ROUND=1' \
        'ROUND_COUNT=3' \
        'QUOTA_MULTIPLIER=5' >"$network_path/burn.params"
    cast() {
        [ "$1" = "chain-id" ] && printf '31337\n'
    }
    source script/deploy/00_init.sh "$network_name"
)

resolve_symbols() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local network_name="resolve_symbols_$$"
    local network_path="$REPO_ROOT/script/network/$network_name"
    mkdir -p "$network_path"
    trap "rm -rf '$network_path'" EXIT
    printf '%s\n' \
        'KEYSTORE_ACCOUNT=deployer' \
        'ACCOUNT_ADDRESS=0x3333333333333333333333333333333333333333' >"$network_path/.account"
    printf '%s\n' 'RPC_URL=http://mock' 'CHAIN_ID=70001' >"$network_path/network.params"
    printf '%s\n' \
        'EXTENSION_CENTER=0x1111111111111111111111111111111111111111' \
        'SCOPE_TOKEN_SYMBOL=FIRST' \
        'COMMUNITY_SYMBOLS=FIRST,CHILD' \
        'COMMUNITY_WEIGHTS=100,200' \
        'CATEGORY_WEIGHTS=1:1:1:1' \
        'START_ROUND=1' \
        'ROUND_COUNT=3' \
        'QUOTA_MULTIPLIER=5' >"$network_path/burn.params"

    cast() {
        if [ "$1" = "chain-id" ]; then printf '70001\n'; return; fi
        local address=$2
        local signature=$3
        local argument=${4:-}
        case "$address:$signature:$argument" in
            0x1111111111111111111111111111111111111111:launchAddress\(\)\(address\):--rpc-url) printf '0x2222222222222222222222222222222222222222\n' ;;
            0x2222222222222222222222222222222222222222:tokenAddressBySymbol\(string\)\(address\):FIRST) printf '0x4444444444444444444444444444444444444444\n' ;;
            0x2222222222222222222222222222222222222222:tokenAddressBySymbol\(string\)\(address\):CHILD) printf '0x5555555555555555555555555555555555555555\n' ;;
            0x2222222222222222222222222222222222222222:isLOVE20Token\(address\)\(bool\):0x4444444444444444444444444444444444444444) printf 'true\n' ;;
            0x2222222222222222222222222222222222222222:isLOVE20Token\(address\)\(bool\):0x5555555555555555555555555555555555555555) printf 'true\n' ;;
            *) return 1 ;;
        esac
    }

    KEYSTORE_PASSWORD=secret
    KEYSTORE_PASSWORD_ACCOUNT=deployer
    source script/deploy/00_init.sh "$network_name" || exit 1
    [ "$SCOPE_TOKEN" = 0x4444444444444444444444444444444444444444 ]
    [ "$COMMUNITY_TOKENS" = 0x4444444444444444444444444444444444444444,0x5555555555555555555555555555555555555555 ]
)

reject_unknown_symbol() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local network_name="reject_unknown_symbol_$$"
    local network_path="$REPO_ROOT/script/network/$network_name"
    mkdir -p "$network_path"
    trap "rm -rf '$network_path'" EXIT
    : >"$network_path/.account"
    printf '%s\n' 'RPC_URL=http://mock' 'CHAIN_ID=70001' >"$network_path/network.params"
    printf '%s\n' \
        'EXTENSION_CENTER=0x1111111111111111111111111111111111111111' \
        'SCOPE_TOKEN_SYMBOL=UNKNOWN' \
        'COMMUNITY_SYMBOLS=UNKNOWN' \
        'COMMUNITY_WEIGHTS=1' \
        'CATEGORY_WEIGHTS=1:1:1:1' \
        'START_ROUND=1' \
        'ROUND_COUNT=3' \
        'QUOTA_MULTIPLIER=5' >"$network_path/burn.params"

    cast() {
        if [ "$1" = "chain-id" ]; then printf '70001\n'; return; fi
        case "$2:$3" in
            0x1111111111111111111111111111111111111111:launchAddress\(\)\(address\)) printf '0x2222222222222222222222222222222222222222\n' ;;
            0x2222222222222222222222222222222222222222:tokenAddressBySymbol\(string\)\(address\)) printf '0x0000000000000000000000000000000000000000\n' ;;
            0x2222222222222222222222222222222222222222:isLOVE20Token\(address\)\(bool\)) printf 'false\n' ;;
            *) return 1 ;;
        esac
    }

    source script/deploy/00_init.sh "$network_name"
)

deploy_address_failure() (
    set +u
    cd "$REPO_ROOT" || exit 1
    RPC_URL=http://127.0.0.1:8545
    network_dir=/does/not/exist
    forge_script() { return 0; }
    source script/deploy/01_deploy_burn.sh
)

deploy_address_value() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    printf 'burnAddress=%s\n' "$1" >"$temp_dir/address.burn.params"
    RPC_URL=http://127.0.0.1:8545
    network_dir=$temp_dir
    forge_script() { return 0; }
    source script/deploy/01_deploy_burn.sh
)

deploy_stale_address() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    : >"$temp_dir/address.burn.params"
    RPC_URL=http://127.0.0.1:8545
    network_dir=$temp_dir
    burnAddress=0x1111111111111111111111111111111111111111
    forge_script() { return 0; }
    source script/deploy/01_deploy_burn.sh
)

prepare_config() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local network_name="prepare_config_$$"
    local network_path="$REPO_ROOT/script/network/$network_name"
    mkdir -p "$network_path"
    trap "rm -rf '$network_path'" EXIT
    printf '%s\n' 'RPC_URL=http://mock' 'CHAIN_ID=70001' >"$network_path/network.params"
    printf '%s\n' \
        'EXTENSION_CENTER=0x1111111111111111111111111111111111111111' \
        'SCOPE_TOKEN_SYMBOL=' \
        'COMMUNITY_SYMBOLS=' \
        'COMMUNITY_WEIGHTS=' \
        'CATEGORY_WEIGHTS=1:1:1:1' \
        'START_ROUND=' \
        'ROUND_COUNT=' \
        'QUOTA_MULTIPLIER=' >"$network_path/burn.params"

    cast() {
        if [ "$1" = "chain-id" ]; then printf '70001\n'; return; fi
        local address=$2
        local signature=$3
        local argument=${4:-}
        [ "$argument" = "--rpc-url" ] && argument=
        case "$address:$signature:$argument" in
            0x1111111111111111111111111111111111111111:launchAddress\(\)\(address\):) printf '0x2222222222222222222222222222222222222222\n' ;;
            0x2222222222222222222222222222222222222222:launchedTokensCount\(\)\(uint256\):) printf '2\n' ;;
            0x2222222222222222222222222222222222222222:launchedTokensAtIndex\(uint256\)\(address\):0) printf '0x4444444444444444444444444444444444444444\n' ;;
            0x2222222222222222222222222222222222222222:launchedTokensAtIndex\(uint256\)\(address\):1) printf '0x5555555555555555555555555555555555555555\n' ;;
            0x4444444444444444444444444444444444444444:symbol\(\)\(string\):) printf '"FIRST"\n' ;;
            0x5555555555555555555555555555555555555555:symbol\(\)\(string\):) printf '"CHILD"\n' ;;
            0x4444444444444444444444444444444444444444:parentTokenAddress\(\)\(address\):) printf '0x7777777777777777777777777777777777777777\n' ;;
            0x5555555555555555555555555555555555555555:parentTokenAddress\(\)\(address\):) printf '0x4444444444444444444444444444444444444444\n' ;;
            0x4444444444444444444444444444444444444444:slAddress\(\)\(address\):) printf '0x8888888888888888888888888888888888888888\n' ;;
            0x5555555555555555555555555555555555555555:slAddress\(\)\(address\):) printf '0x9999999999999999999999999999999999999999\n' ;;
            0x8888888888888888888888888888888888888888:tokenAmounts\(\)\(uint256,uint256,uint256,uint256\):) printf '100\n10\n0\n0\n' ;;
            0x9999999999999999999999999999999999999999:tokenAmounts\(\)\(uint256,uint256,uint256,uint256\):) printf '20\n200\n0\n0\n' ;;
            *) return 1 ;;
        esac
    }

    local output
    output=$(source script/deploy/00_prepare_config.sh "$network_name") || exit 1
    [[ "$output" == *'SCOPE_TOKEN_SYMBOL=FIRST'* ]] || exit 1
    [[ "$output" == *'COMMUNITY_SYMBOLS=FIRST,CHILD'* ]] || exit 1
    [[ "$output" == *'COMMUNITY_WEIGHTS=100,200'* ]] || exit 1
    [[ "$output" == *'CATEGORY_WEIGHTS=1:1:1:1'* ]] || exit 1
    [ ! -e "$network_path/burn.proposed.params" ]
)

assert_fails_with \
    '00_init rejects dynamic start round' \
    'START_ROUND must be an explicit non-negative integer' \
    invalid_start_round
assert_fails_with \
    '00_init rejects malformed category weights' \
    'CATEGORY_WEIGHTS must contain four positive integers separated by :' \
    invalid_category_weights
assert_succeeds '00_init resolves Launch token symbols' resolve_symbols
assert_fails_with \
    '00_init rejects symbols not issued by Launch' \
    'UNKNOWN is not a token issued by Launch' \
    reject_unknown_symbol
assert_fails_with \
    '01_deploy_burn rejects missing address file' \
    'Failed to read address.burn.params' \
    deploy_address_failure
assert_fails_with \
    '01_deploy_burn rejects empty burn address' \
    'burnAddress is empty after deploy' \
    deploy_address_value ''
assert_fails_with \
    '01_deploy_burn rejects invalid burn address' \
    'burnAddress is invalid after deploy' \
    deploy_address_value invalid
assert_fails_with \
    '01_deploy_burn rejects stale burn address' \
    'burnAddress is empty after deploy' \
    deploy_stale_address
assert_succeeds '00_prepare_config generates first-token weights' prepare_config

if [ "$failures" -ne 0 ]; then
    exit 1
fi
