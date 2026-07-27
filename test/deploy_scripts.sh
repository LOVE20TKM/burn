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
        'SCOPE_TOKEN=0x2222222222222222222222222222222222222222' \
        'COMMUNITY_TOKENS=0x2222222222222222222222222222222222222222' \
        'COMMUNITY_WEIGHTS=1' \
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

assert_fails_with \
    '00_init rejects dynamic start round' \
    'START_ROUND must be an explicit non-negative integer' \
    invalid_start_round
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

if [ "$failures" -ne 0 ]; then
    exit 1
fi
