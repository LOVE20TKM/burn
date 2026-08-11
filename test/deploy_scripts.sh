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
        'SL_TOKEN_LOCK_WEIGHT=1' \
        'ST_TOKEN_LOCK_WEIGHT=1' \
        'GOV_REWARD_BURN_WEIGHT=1' \
        'ACTION_REWARD_BURN_WEIGHT=1' \
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
    local sl_weight=$1
    local st_weight=$2
    local gov_weight=$3
    local action_weight=$4
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
        "SL_TOKEN_LOCK_WEIGHT=$sl_weight" \
        "ST_TOKEN_LOCK_WEIGHT=$st_weight" \
        "GOV_REWARD_BURN_WEIGHT=$gov_weight" \
        "ACTION_REWARD_BURN_WEIGHT=$action_weight" \
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
        'SL_TOKEN_LOCK_WEIGHT=0' \
        'ST_TOKEN_LOCK_WEIGHT=1' \
        'GOV_REWARD_BURN_WEIGHT=1' \
        'ACTION_REWARD_BURN_WEIGHT=1' \
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
        'SL_TOKEN_LOCK_WEIGHT=1' \
        'ST_TOKEN_LOCK_WEIGHT=1' \
        'GOV_REWARD_BURN_WEIGHT=1' \
        'ACTION_REWARD_BURN_WEIGHT=1' \
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
        'SL_TOKEN_LOCK_WEIGHT=1' \
        'ST_TOKEN_LOCK_WEIGHT=1' \
        'GOV_REWARD_BURN_WEIGHT=1' \
        'ACTION_REWARD_BURN_WEIGHT=1' \
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
    [[ "$output" == *'SL_TOKEN_LOCK_WEIGHT=1'* ]] || exit 1
    [[ "$output" == *'ST_TOKEN_LOCK_WEIGHT=1'* ]] || exit 1
    [[ "$output" == *'GOV_REWARD_BURN_WEIGHT=1'* ]] || exit 1
    [[ "$output" == *'ACTION_REWARD_BURN_WEIGHT=1'* ]] || exit 1
    [ ! -e "$network_path/burn.proposed.params" ]
)

airdrop_missing_params() (
    set +u
    cd "$REPO_ROOT" || exit 1
    source script/deploy/one_click_deploy_airdrop.sh
)

airdrop_multiple_pending_snapshots() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local source_name="airdrop_multiple_source_$$"
    local target_name="airdrop_multiple_target_$$"
    local source_path="$REPO_ROOT/script/network/$source_name"
    local target_path="$REPO_ROOT/script/network/$target_name"
    local prefix=70001-0x1111111111111111111111111111111111111111
    mkdir -p "$source_path" "$target_path/airdrops/$prefix-123" "$target_path/airdrops/$prefix-456"
    trap "rm -rf '$source_path' '$target_path'" EXIT
    printf '%s\n' 'RPC_URL=http://source' 'CHAIN_ID=70001' >"$source_path/network.params"
    printf '%s\n' 'burnAddress=0x1111111111111111111111111111111111111111' >"$source_path/address.burn.params"
    : >"$target_path/.account"
    printf '%s\n' 'RPC_URL=http://target' 'CHAIN_ID=56' >"$target_path/network.params"
    source script/deploy/one_click_deploy_airdrop.sh "$source_name" "$target_name"
)

airdrop_requested_block_does_not_reuse_other_snapshot() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local source_name="airdrop_requested_source_$$"
    local target_name="airdrop_requested_target_$$"
    local source_path="$REPO_ROOT/script/network/$source_name"
    local target_path="$REPO_ROOT/script/network/$target_name"
    local source_burn=0x1111111111111111111111111111111111111111
    mkdir -p "$source_path" "$target_path/airdrops/70001-$source_burn-123"
    trap "rm -rf '$source_path' '$target_path'" EXIT
    printf '%s\n' 'RPC_URL=http://source' 'CHAIN_ID=70001' >"$source_path/network.params"
    printf 'burnAddress=%s\n' "$source_burn" >"$source_path/address.burn.params"
    : >"$target_path/.account"
    printf '%s\n' 'RPC_URL=http://target' 'CHAIN_ID=56' >"$target_path/network.params"
    cast() {
        case "$1" in
            chain-id) printf '70001\n' ;;
            code) printf '0x6000\n' ;;
            *) return 1 ;;
        esac
    }
    export -f cast
    SOURCE_BLOCK_NUMBER=456 source script/deploy/one_click_deploy_airdrop.sh "$source_name" "$target_name"
)

airdrop_zsh_reuses_single_pending_snapshot() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local source_name="airdrop_zsh_source_$$"
    local target_name="airdrop_zsh_target_$$"
    local source_path="$REPO_ROOT/script/network/$source_name"
    local target_path="$REPO_ROOT/script/network/$target_name"
    local source_burn=0x1111111111111111111111111111111111111111
    local snapshot_path="$target_path/airdrops/70001-$source_burn-123"
    mkdir -p "$source_path" "$snapshot_path"
    trap "rm -rf '$source_path' '$target_path'" EXIT
    printf '%s\n' 'RPC_URL=http://source' 'CHAIN_ID=70001' >"$source_path/network.params"
    printf 'burnAddress=%s\n' "$source_burn" >"$source_path/address.burn.params"
    : >"$target_path/.account"
    printf '%s\n' 'RPC_URL=http://target' 'CHAIN_ID=56' >"$target_path/network.params"

    local output status=0
    output=$(zsh -c 'source script/deploy/one_click_deploy_airdrop.sh "$1" "$2"' zsh "$source_name" "$target_name" 2>&1) || status=$?
    [ "$status" -ne 0 ] || exit 1
    [[ "$output" == *"Reviewed snapshot not found: $snapshot_path"* ]]
)

airdrop_deploy_and_check() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local source_name="airdrop_source_$$"
    local target_name="airdrop_target_$$"
    local source_path="$REPO_ROOT/script/network/$source_name"
    local target_path="$REPO_ROOT/script/network/$target_name"
    local deployed=0x2222222222222222222222222222222222222222
    local source_burn=0x1111111111111111111111111111111111111111
    local root=0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local snapshot_id="70001-$source_burn-123"
    local snapshot_path="$target_path/airdrops/$snapshot_id"
    local old_snapshot="$target_path/airdrops/old"
    mkdir -p "$source_path" "$old_snapshot"
    trap "rm -rf '$source_path' '$target_path'" EXIT
    printf '%s\n' 'RPC_URL=http://source' 'CHAIN_ID=70001' >"$source_path/network.params"
    printf 'burnAddress=%s\n' "$source_burn" >"$source_path/address.burn.params"
    printf '%s\n' \
        'KEYSTORE_ACCOUNT=deployer' \
        'ACCOUNT_ADDRESS=0x3333333333333333333333333333333333333333' >"$target_path/.account"
    printf '%s\n' 'RPC_URL=http://target' 'CHAIN_ID=56' >"$target_path/network.params"
    printf 'keep\n' >"$old_snapshot/sentinel"

    cast() {
        case "$1" in
            chain-id)
                case "$3" in
                    http://source) printf '70001\n' ;;
                    http://target) printf '56\n' ;;
                    *) return 1 ;;
                esac
                ;;
            code) printf '0x6000\n' ;;
            block-number) printf '123\n' ;;
            call)
                case "$3" in
                    sourceChainId\(\)\(uint256\)) printf '70001 [7e4]\n' ;;
                    sourceBlockNumber\(\)\(uint256\)) printf '123\n' ;;
                    sourceBurnAddress\(\)\(address\)) printf '%s\n' "$MOCK_SOURCE_BURN" ;;
                    merkleRoot\(\)\(bytes32\)) printf '%s\n' "$MOCK_ROOT" ;;
                    totalShare\(\)\(uint256\)) printf '900000000000000000\n' ;;
                    *) return 1 ;;
                esac
                ;;
            *) return 1 ;;
        esac
    }
    forge() {
        case "$2" in
            *ValidateAirdropSnapshot*)
                return 0
                ;;
            *GenerateAirdropSnapshot*)
                printf '%s\n' \
                    '{' \
                    '  "sourceChainId": "70001",' \
                    '  "sourceBlockNumber": "123",' \
                    "  \"sourceBurnAddress\": \"$MOCK_SOURCE_BURN\"," \
                    "  \"merkleRoot\": \"$MOCK_ROOT\"," \
                    '  "totalShare": "900000000000000000",' \
                    '  "accountCount": "0",' \
                    '  "entries": []' \
                    '}' >"$SNAPSHOT_OUTPUT"
                ;;
            *DeployAirdrop*)
                [ "$network" = "$MOCK_DEPLOYMENT_NETWORK" ] || return 1
                printf 'airdropAddress=%s\n' "$MOCK_DEPLOYED" >"$MOCK_SNAPSHOT_PATH/address.airdrop.params"
                ;;
            *) return 1 ;;
        esac
    }
    export MOCK_DEPLOYED="$deployed" MOCK_SOURCE_BURN="$source_burn" MOCK_ROOT="$root"
    export MOCK_SNAPSHOT_PATH="$snapshot_path" SOURCE_BLOCK_NUMBER=123
    export MOCK_DEPLOYMENT_NETWORK="$target_name/airdrops/$snapshot_id"
    export -f cast forge

    KEYSTORE_PASSWORD=secret
    KEYSTORE_PASSWORD_ACCOUNT=deployer
    source script/deploy/one_click_deploy_airdrop.sh "$source_name" "$target_name" || exit 1
    [ "$airdropAddress" = "$deployed" ] || exit 1
    [ -f "$snapshot_path/airdrop-deployment.json" ] || exit 1
    grep -Fq "\"airdropAddress\": \"$deployed\"" "$snapshot_path/airdrop-deployment.json" || exit 1
    grep -Fq "\"merkleRoot\": \"$root\"" "$snapshot_path/airdrop-deployment.json" || exit 1
    grep -Fxq keep "$old_snapshot/sentinel"
)

airdrop_failed_check_preserves_and_resumes() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local source_name="airdrop_failed_source_$$"
    local target_name="airdrop_failed_target_$$"
    local source_path="$REPO_ROOT/script/network/$source_name"
    local target_path="$REPO_ROOT/script/network/$target_name"
    local deployed=0x2222222222222222222222222222222222222222
    local source_burn=0x1111111111111111111111111111111111111111
    local root=0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local snapshot_path="$target_path/airdrops/70001-$source_burn-123"
    mkdir -p "$source_path" "$snapshot_path"
    trap "rm -rf '$source_path' '$target_path'" EXIT
    printf '%s\n' 'RPC_URL=http://source' 'CHAIN_ID=70001' >"$source_path/network.params"
    printf 'burnAddress=%s\n' "$source_burn" >"$source_path/address.burn.params"
    printf '%s\n' \
        'KEYSTORE_ACCOUNT=deployer' \
        'ACCOUNT_ADDRESS=0x3333333333333333333333333333333333333333' >"$target_path/.account"
    printf '%s\n' 'RPC_URL=http://target' 'CHAIN_ID=56' >"$target_path/network.params"
    printf '%s\n' \
        '{' \
        '  "sourceChainId": "70001",' \
        '  "sourceBlockNumber": "123",' \
        "  \"sourceBurnAddress\": \"$source_burn\"," \
        "  \"merkleRoot\": \"$root\"," \
        '  "totalShare": "900000000000000000",' \
        '  "accountCount": "0",' \
        '  "entries": []' \
        '}' >"$snapshot_path/airdrop-snapshot.json"
    printf '%s\n' \
        'SOURCE_CHAIN_ID=70001' \
        'SOURCE_BLOCK_NUMBER=123' \
        "SOURCE_BURN=$source_burn" \
        "MERKLE_ROOT=$root" \
        'TOTAL_SHARE=900000000000000000' >"$snapshot_path/airdrop.params"

    CHECK_READY=0
    DEPLOY_COUNT=0
    cast() {
        case "$1" in
            chain-id) printf '56\n' ;;
            code) [ "$CHECK_READY" = 1 ] && printf '0x6000\n' || printf '0x\n' ;;
            call)
                case "$3" in
                    sourceChainId\(\)\(uint256\)) printf '70001\n' ;;
                    sourceBlockNumber\(\)\(uint256\)) printf '123\n' ;;
                    sourceBurnAddress\(\)\(address\)) printf '%s\n' "$source_burn" ;;
                    merkleRoot\(\)\(bytes32\)) printf '%s\n' "$root" ;;
                    totalShare\(\)\(uint256\)) printf '900000000000000000\n' ;;
                    *) return 1 ;;
                esac
                ;;
            *) return 1 ;;
        esac
    }
    forge() {
        case "$2" in
            *ValidateAirdropSnapshot*) return 0 ;;
            *DeployAirdrop*)
                DEPLOY_COUNT=$((DEPLOY_COUNT + 1))
                printf 'airdropAddress=%s\n' "$deployed" >"$snapshot_path/address.airdrop.params"
                [ "$DEPLOY_COUNT" -gt 1 ] || return 1
                [[ " $* " == *' --resume '* ]]
                ;;
            *) return 1 ;;
        esac
    }
    export -f cast forge

    KEYSTORE_PASSWORD=secret
    KEYSTORE_PASSWORD_ACCOUNT=deployer
    local status=0
    source script/deploy/one_click_deploy_airdrop.sh "$source_name" "$target_name" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ] || exit 1
    [ "$DEPLOY_COUNT" -eq 1 ] || exit 1
    [ -f "$snapshot_path/airdrop-snapshot.json" ] || exit 1
    [ -f "$snapshot_path/airdrop.params" ] || exit 1
    [ -f "$snapshot_path/address.airdrop.params" ] || exit 1
    [ ! -e "$snapshot_path/airdrop-deployment.json" ] || exit 1

    status=0
    source script/deploy/one_click_deploy_airdrop.sh "$source_name" "$target_name" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ] || exit 1
    [ "$DEPLOY_COUNT" -eq 2 ] || exit 1

    CHECK_READY=1
    source script/deploy/one_click_deploy_airdrop.sh "$source_name" "$target_name" >/dev/null 2>&1 || exit 1
    [ "$DEPLOY_COUNT" -eq 2 ] || exit 1
    [ -f "$snapshot_path/airdrop-deployment.json" ]
)

snapshot_missing_target() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local source_name="snapshot_source_$$"
    local target_name="snapshot_missing_target_$$"
    local source_path="$REPO_ROOT/script/network/$source_name"
    mkdir -p "$source_path"
    trap "rm -rf '$source_path'" EXIT
    printf '%s\n' 'RPC_URL=http://mock' 'CHAIN_ID=70001' >"$source_path/network.params"
    printf '%s\n' 'burnAddress=0x1111111111111111111111111111111111111111' >"$source_path/address.burn.params"
    bash script/deploy/generate_airdrop_snapshot.sh "$source_name" "$target_name"
)

snapshot_chain_mismatch() (
    set +u
    cd "$REPO_ROOT" || exit 1
    local source_name="snapshot_chain_mismatch_source_$$"
    local target_name="snapshot_chain_mismatch_target_$$"
    local source_path="$REPO_ROOT/script/network/$source_name"
    local target_path="$REPO_ROOT/script/network/$target_name"
    mkdir -p "$source_path" "$target_path"
    trap "rm -rf '$source_path' '$target_path'" EXIT
    printf '%s\n' 'RPC_URL=http://mock' 'CHAIN_ID=70001' >"$source_path/network.params"
    printf '%s\n' 'burnAddress=0x1111111111111111111111111111111111111111' >"$source_path/address.burn.params"
    cast() {
        [ "$1" = chain-id ] && printf '56\n'
    }
    export -f cast
    bash script/deploy/generate_airdrop_snapshot.sh "$source_name" "$target_name"
)

snapshot_generate() (
    set +u
    cd "$REPO_ROOT" || exit 1
    unset SOURCE_BLOCK_NUMBER
    export MOCK_BLOCK=456
    local source_name="snapshot_generate_source_$$"
    local target_name="snapshot_generate_target_$$"
    local source_path="$REPO_ROOT/script/network/$source_name"
    local target_path="$REPO_ROOT/script/network/$target_name"
    local source_burn=0x1111111111111111111111111111111111111111
    local root=0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local snapshot_path="$target_path/airdrops/70001-$source_burn-456"
    mkdir -p "$source_path" "$target_path"
    trap "rm -rf '$source_path' '$target_path'" EXIT
    printf '%s\n' 'RPC_URL=http://mock' 'CHAIN_ID=70001' >"$source_path/network.params"
    printf 'burnAddress=%s\n' "$source_burn" >"$source_path/address.burn.params"

    cast() {
        case "$1" in
            chain-id) printf '70001\n' ;;
            code) printf '0x6000\n' ;;
            block-number) printf '%s\n' "$MOCK_BLOCK" ;;
            *) return 1 ;;
        esac
    }
    forge() {
        [ "$SOURCE_CHAIN_ID" = 70001 ] || return 1
        [ "$SOURCE_BLOCK_NUMBER" = 456 ] || return 1
        [ "$SOURCE_BURN" = "$EXPECTED_SOURCE_BURN" ] || return 1
        [[ " $* " == *' --fork-block-number 456 '* ]] || return 1
        [[ " $* " == *' --force '* ]] || return 1
        printf '%s\n' \
            '{' \
            '  "sourceChainId": "70001",' \
            '  "sourceBlockNumber": "456",' \
            "  \"sourceBurnAddress\": \"$EXPECTED_SOURCE_BURN\"," \
            "  \"merkleRoot\": \"$EXPECTED_ROOT\"," \
            '  "totalShare": "900000000000000000",' \
            '  "accountCount": "0",' \
            '  "entries": []' \
            '}' >"$SNAPSHOT_OUTPUT"
    }
    export EXPECTED_SOURCE_BURN="$source_burn" EXPECTED_ROOT="$root"
    export -f cast forge

    bash script/deploy/generate_airdrop_snapshot.sh "$source_name" "$target_name" || exit 1
    [ -f "$snapshot_path/airdrop-snapshot.json" ] || exit 1
    source "$snapshot_path/airdrop.params" || exit 1
    [ "$SOURCE_CHAIN_ID" = 70001 ] || exit 1
    [ "$SOURCE_BLOCK_NUMBER" = 456 ] || exit 1
    [ "$SOURCE_BURN" = "$source_burn" ] || exit 1
    [ "$MERKLE_ROOT" = "$root" ] || exit 1
    [ "$TOTAL_SHARE" = 900000000000000000 ] || exit 1

    export MOCK_BLOCK=457
    local output status=0
    output=$(bash script/deploy/generate_airdrop_snapshot.sh "$source_name" "$target_name" 2>&1) || status=$?
    [ "$status" -ne 0 ] || exit 1
    [[ "$output" == *'Pending Airdrop snapshot already exists'* ]]
)

assert_fails_with \
    '00_init rejects dynamic start round' \
    'START_ROUND must be an explicit non-negative integer' \
    invalid_start_round
assert_fails_with \
    '00_init rejects malformed category weight' \
    'SL_TOKEN_LOCK_WEIGHT must be a non-negative integer' \
    invalid_category_weights invalid 1 1 1
assert_fails_with \
    '00_init rejects all-zero category weights' \
    'At least one category weight must be positive' \
    invalid_category_weights 0 0 0 0
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
assert_fails_with \
    'one_click_deploy_airdrop requires source and target' \
    'Usage:' \
    airdrop_missing_params
assert_fails_with \
    'one_click_deploy_airdrop rejects multiple pending snapshots' \
    'Multiple pending Airdrop snapshots found' \
    airdrop_multiple_pending_snapshots
assert_fails_with \
    'one_click_deploy_airdrop honors requested source block' \
    'Pending Airdrop snapshot already exists' \
    airdrop_requested_block_does_not_reuse_other_snapshot
assert_succeeds 'one_click_deploy_airdrop reuses one pending snapshot from zsh' airdrop_zsh_reuses_single_pending_snapshot
assert_succeeds 'one_click_deploy_airdrop generates and deploys an immutable snapshot' airdrop_deploy_and_check
assert_succeeds 'failed Airdrop broadcast resumes before deployment checks' airdrop_failed_check_preserves_and_resumes
assert_fails_with \
    'generate_airdrop_snapshot requires target directory' \
    'target network directory not found' \
    snapshot_missing_target
assert_fails_with \
    'generate_airdrop_snapshot rejects source chain mismatch' \
    'source RPC unavailable or chain id mismatch' \
    snapshot_chain_mismatch
assert_succeeds 'generate_airdrop_snapshot writes snapshot and target params' snapshot_generate

if [ "$failures" -ne 0 ]; then
    exit 1
fi
