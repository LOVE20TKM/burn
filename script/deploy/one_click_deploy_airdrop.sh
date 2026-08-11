#!/bin/bash

if [ -n "${ZSH_VERSION:-}" ]; then
    SCRIPT_PATH="$0"
else
    SCRIPT_PATH="${BASH_SOURCE[0]}"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_ROOT="$(cd "$SCRIPT_DIR/../network" && pwd)"
cd "$REPO_ROOT" || return 1 2>/dev/null || exit 1

source_network=${1:-}
target_network=${2:-}
requested_source_block=${SOURCE_BLOCK_NUMBER:-}
source_dir="$NETWORK_ROOT/$source_network"
network_dir="$NETWORK_ROOT/$target_network"

if [ -z "$source_network" ] || [ -z "$target_network" ]; then
    echo -e "\033[31mError:\033[0m Usage: $0 <source-network> <target-network>"
    return 1 2>/dev/null || exit 1
fi
if [ -n "$requested_source_block" ] \
    && { [[ ! "$requested_source_block" =~ ^[0-9]+$ ]] || [ "$requested_source_block" -le 0 ]; }; then
    echo -e "\033[31mError:\033[0m SOURCE_BLOCK_NUMBER must be a positive integer"
    return 1 2>/dev/null || exit 1
fi
if [ ! -f "$source_dir/network.params" ] || [ ! -f "$source_dir/address.burn.params" ]; then
    echo -e "\033[31mError:\033[0m Source network.params or address.burn.params not found"
    return 1 2>/dev/null || exit 1
fi
if [ ! -d "$network_dir" ]; then
    echo -e "\033[31mError:\033[0m Target network directory not found"
    return 1 2>/dev/null || exit 1
fi
if [ ! -f "$network_dir/.account" ]; then
    echo -e "\033[31mError:\033[0m .account file not found"
    return 1 2>/dev/null || exit 1
fi
if [ ! -f "$network_dir/network.params" ]; then
    echo -e "\033[31mError:\033[0m network.params not found"
    return 1 2>/dev/null || exit 1
fi

unset RPC_URL CHAIN_ID burnAddress
set -a
source "$source_dir/network.params"
source "$source_dir/address.burn.params"
set +a
expected_source_chain_id=${CHAIN_ID:-}
expected_source_burn=${burnAddress:-}
if [[ ! "$expected_source_chain_id" =~ ^[0-9]+$ ]] || [[ ! "$expected_source_burn" =~ ^0x[[:xdigit:]]{40}$ ]]; then
    echo -e "\033[31mError:\033[0m Source chain id or Burn address is invalid"
    return 1 2>/dev/null || exit 1
fi

snapshot_prefix="$expected_source_chain_id-$(printf '%s' "$expected_source_burn" | tr '[:upper:]' '[:lower:]')-"
snapshot_pattern="$snapshot_prefix*"
[ -z "$requested_source_block" ] || snapshot_pattern="$snapshot_prefix$requested_source_block"
find_pending_snapshots() {
    snapshot_dirs=()
    [ -d "$network_dir/airdrops" ] || return 0
    while IFS= read -r candidate; do
        [ -f "$candidate/airdrop-deployment.json" ] || snapshot_dirs+=("$candidate")
    done < <(find "$network_dir/airdrops" -mindepth 1 -maxdepth 1 -type d -name "$snapshot_pattern" -print)
}
find_pending_snapshots
echo -e "\n[1/5] Prepare Airdrop snapshot"
if [ "${#snapshot_dirs[@]}" -eq 0 ]; then
    if ! SOURCE_BLOCK_NUMBER="$requested_source_block" \
        bash "$SCRIPT_DIR/generate_airdrop_snapshot.sh" "$source_network" "$target_network"; then
        echo -e "\033[31mError:\033[0m Failed to generate finalized Airdrop snapshot"
        return 1 2>/dev/null || exit 1
    fi
    find_pending_snapshots
else
    echo -e "\033[33mReuse:\033[0m Using the existing pending snapshot"
fi
if [ "${#snapshot_dirs[@]}" -eq 0 ]; then
    echo -e "\033[31mError:\033[0m No pending Airdrop snapshot found after generation"
    return 1 2>/dev/null || exit 1
fi
if [ "${#snapshot_dirs[@]}" -ne 1 ]; then
    echo -e "\033[31mError:\033[0m Multiple pending Airdrop snapshots found:"
    printf '  %s\n' "${snapshot_dirs[@]}"
    return 1 2>/dev/null || exit 1
fi
snapshot_dir=
for candidate in "${snapshot_dirs[@]}"; do
    snapshot_dir=$candidate
    break
done
snapshot_id=${snapshot_dir##*/}
snapshot_file="$snapshot_dir/airdrop-snapshot.json"
params_file="$snapshot_dir/airdrop.params"
address_file="$snapshot_dir/address.airdrop.params"
manifest="$snapshot_dir/airdrop-deployment.json"
deployment_network="$target_network/airdrops/$snapshot_id"

echo -e "\n[2/5] Validate Airdrop snapshot"
if [ ! -f "$params_file" ] || [ ! -f "$snapshot_file" ]; then
    echo -e "\033[31mError:\033[0m Reviewed snapshot not found: $snapshot_dir"
    return 1 2>/dev/null || exit 1
fi

unset RPC_URL CHAIN_ID burnAddress SOURCE_CHAIN_ID SOURCE_BLOCK_NUMBER SOURCE_BURN MERKLE_ROOT TOTAL_SHARE
set -a
source "$network_dir/.account"
source "$network_dir/network.params"
source "$params_file"
set +a
network="$deployment_network"
export network

actual_chain_id=$(cast chain-id --rpc-url "${RPC_URL:-}" 2>/dev/null)
if [ -z "${RPC_URL:-}" ] || [ -z "${CHAIN_ID:-}" ] || [ "$actual_chain_id" != "$CHAIN_ID" ]; then
    echo -e "\033[31mError:\033[0m RPC unavailable or chain id mismatch"
    return 1 2>/dev/null || exit 1
fi

for name in SOURCE_CHAIN_ID SOURCE_BLOCK_NUMBER SOURCE_BURN MERKLE_ROOT TOTAL_SHARE; do
    if [ -z "$(printenv "$name")" ]; then
        echo -e "\033[31mError:\033[0m $name is required in airdrop.params"
        return 1 2>/dev/null || exit 1
    fi
done
for name in SOURCE_CHAIN_ID SOURCE_BLOCK_NUMBER TOTAL_SHARE; do
    if [[ ! "$(printenv "$name")" =~ ^[0-9]+$ ]] || [ "$(printenv "$name")" -le 0 ]; then
        echo -e "\033[31mError:\033[0m $name must be a positive integer"
        return 1 2>/dev/null || exit 1
    fi
done
if [[ ! "$SOURCE_BURN" =~ ^0x[[:xdigit:]]{40}$ ]]; then
    echo -e "\033[31mError:\033[0m SOURCE_BURN is not an address"
    return 1 2>/dev/null || exit 1
fi
if [[ ! "$MERKLE_ROOT" =~ ^0x[[:xdigit:]]{64}$ ]]; then
    echo -e "\033[31mError:\033[0m MERKLE_ROOT is not bytes32"
    return 1 2>/dev/null || exit 1
fi
if [ "$TOTAL_SHARE" -gt 1000000000000000000 ]; then
    echo -e "\033[31mError:\033[0m TOTAL_SHARE must not exceed 1e18"
    return 1 2>/dev/null || exit 1
fi
expected_snapshot_id="$expected_source_chain_id-$(printf '%s' "$expected_source_burn" | tr '[:upper:]' '[:lower:]')-$SOURCE_BLOCK_NUMBER"
if [ "$SOURCE_CHAIN_ID" != "$expected_source_chain_id" ] \
    || [ "$(printf '%s' "$SOURCE_BURN" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$expected_source_burn" | tr '[:upper:]' '[:lower:]')" ] \
    || [ "$snapshot_id" != "$expected_snapshot_id" ]; then
    echo -e "\033[31mError:\033[0m Snapshot does not match the requested source"
    return 1 2>/dev/null || exit 1
fi

snapshot_value() {
    sed -nE "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*$/\1/p" "$snapshot_file"
}

snapshot_source_chain_id=$(snapshot_value sourceChainId)
snapshot_source_block=$(snapshot_value sourceBlockNumber)
snapshot_source_burn=$(snapshot_value sourceBurnAddress)
snapshot_merkle_root=$(snapshot_value merkleRoot)
snapshot_total_share=$(snapshot_value totalShare)
if [ "$snapshot_source_chain_id" != "$SOURCE_CHAIN_ID" ] \
    || [ "$snapshot_source_block" != "$SOURCE_BLOCK_NUMBER" ] \
    || [ "$(printf '%s' "$snapshot_source_burn" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$SOURCE_BURN" | tr '[:upper:]' '[:lower:]')" ] \
    || [ "$(printf '%s' "$snapshot_merkle_root" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$MERKLE_ROOT" | tr '[:upper:]' '[:lower:]')" ] \
    || [ "$snapshot_total_share" != "$TOTAL_SHARE" ]; then
    echo -e "\033[31mError:\033[0m airdrop-snapshot.json does not match airdrop.params"
    return 1 2>/dev/null || exit 1
fi

validate_snapshot() {
    local airdrop_address=${1:-0x0000000000000000000000000000000000000000}
    if ! SNAPSHOT_INPUT="$snapshot_file" \
        AIRDROP_ADDRESS="$airdrop_address" \
        SOURCE_CHAIN_ID="$SOURCE_CHAIN_ID" \
        SOURCE_BLOCK_NUMBER="$SOURCE_BLOCK_NUMBER" \
        SOURCE_BURN="$SOURCE_BURN" \
        MERKLE_ROOT="$MERKLE_ROOT" \
        TOTAL_SHARE="$TOTAL_SHARE" \
        forge script script/ValidateAirdropSnapshot.s.sol:ValidateAirdropSnapshot --sig "run()" \
            --rpc-url "$RPC_URL"; then
        return 1
    fi
}

if ! validate_snapshot; then
    echo -e "\033[31mError:\033[0m Snapshot entries or proofs are invalid"
    return 1 2>/dev/null || exit 1
fi
echo -e "\033[32m✓\033[0m Snapshot metadata and every proof validated"

request_keystore_password() {
    if [ -n "${KEYSTORE_PASSWORD:-}" ] && [ "${KEYSTORE_PASSWORD_ACCOUNT:-}" = "$KEYSTORE_ACCOUNT" ]; then
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

echo -e "\n[3/5] Deploy or resume Airdrop"
unset airdropAddress
resume_args=()
broadcast_required=true
if [ -f "$address_file" ]; then
    if ! source "$address_file"; then
        echo -e "\033[31mError:\033[0m Failed to read address.airdrop.params"
        return 1 2>/dev/null || exit 1
    fi
    if [[ ! "${airdropAddress:-}" =~ ^0x[[:xdigit:]]{40}$ ]]; then
        echo -e "\033[31mError:\033[0m airdropAddress is invalid"
        return 1 2>/dev/null || exit 1
    fi
    if ! existing_code=$(cast code "$airdropAddress" --rpc-url "$RPC_URL" 2>/dev/null) || [ -z "$existing_code" ]; then
        echo -e "\033[31mError:\033[0m Failed to check previously written Airdrop address"
        return 1 2>/dev/null || exit 1
    fi
    if [ "$existing_code" = "0x" ]; then
        resume_args=(--resume)
        echo -e "\033[33mResume:\033[0m Continuing the previously failed Airdrop broadcast"
    else
        broadcast_required=false
        echo -e "\033[33mResume:\033[0m Reusing previously broadcast Airdrop address"
    fi
fi

if [ "$broadcast_required" = true ]; then
    if [ "$target_network" = "anvil" ]; then
        if [ -z "${PRIVATE_KEY:-}" ]; then
            echo -e "\033[31mError:\033[0m PRIVATE_KEY is required for anvil deployment"
            return 1 2>/dev/null || exit 1
        fi
        forge script script/DeployAirdrop.s.sol:DeployAirdrop --sig "run()" \
            --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --sender "$ACCOUNT_ADDRESS" \
            --gas-price 5000000000 --gas-limit 50000000 --broadcast --legacy "${resume_args[@]}"
    else
        if [ -z "${KEYSTORE_ACCOUNT:-}" ] || [ -z "${ACCOUNT_ADDRESS:-}" ]; then
            echo -e "\033[31mError:\033[0m KEYSTORE_ACCOUNT and ACCOUNT_ADDRESS are required"
            return 1 2>/dev/null || exit 1
        fi
        request_keystore_password || return 1 2>/dev/null || exit 1
        forge script script/DeployAirdrop.s.sol:DeployAirdrop --sig "run()" \
            --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" \
            --password "$KEYSTORE_PASSWORD" --gas-price 5000000000 --gas-limit 50000000 --broadcast --legacy \
            "${resume_args[@]}"
    fi
    if [ $? -ne 0 ]; then
        echo -e "\033[31mError:\033[0m Failed to deploy Airdrop; any written address was preserved for retry"
        return 1 2>/dev/null || exit 1
    fi
    if ! source "$address_file"; then
        echo -e "\033[31mError:\033[0m Failed to read address.airdrop.params"
        return 1 2>/dev/null || exit 1
    fi
fi
if [[ ! "${airdropAddress:-}" =~ ^0x[[:xdigit:]]{40}$ ]]; then
    echo -e "\033[31mError:\033[0m airdropAddress is invalid after deploy"
    return 1 2>/dev/null || exit 1
fi

echo -e "\n[4/5] Check deployment"
code=$(cast code "$airdropAddress" --rpc-url "$RPC_URL" 2>/dev/null)
if [ -z "$code" ] || [ "$code" = "0x" ]; then
    echo -e "\033[31mError:\033[0m No Airdrop contract code found; snapshot and address were preserved for retry"
    return 1 2>/dev/null || exit 1
fi

normalize_value() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//;s/^([0-9]+)[[:space:]]+\[[^]]+\]$/\1/'
}
check_equal() {
    local description=$1
    local expected actual
    expected=$(normalize_value "$2")
    actual=$(normalize_value "$3")
    if [ "$expected" = "$actual" ]; then
        echo -e "\033[32m✓\033[0m $description"
        return 0
    fi
    echo -e "\033[31m✗\033[0m $description (expected $expected, actual $actual)"
    return 1
}

failed=0
check_equal "sourceChainId" "$SOURCE_CHAIN_ID" "$(cast call "$airdropAddress" "sourceChainId()(uint256)" --rpc-url "$RPC_URL")" || ((failed++))
check_equal "sourceBlockNumber" "$SOURCE_BLOCK_NUMBER" "$(cast call "$airdropAddress" "sourceBlockNumber()(uint256)" --rpc-url "$RPC_URL")" || ((failed++))
check_equal "sourceBurnAddress" "$SOURCE_BURN" "$(cast call "$airdropAddress" "sourceBurnAddress()(address)" --rpc-url "$RPC_URL")" || ((failed++))
check_equal "merkleRoot" "$MERKLE_ROOT" "$(cast call "$airdropAddress" "merkleRoot()(bytes32)" --rpc-url "$RPC_URL")" || ((failed++))
check_equal "totalShare" "$TOTAL_SHARE" "$(cast call "$airdropAddress" "totalShare()(uint256)" --rpc-url "$RPC_URL")" || ((failed++))

if [ "$failed" -ne 0 ]; then
    echo -e "\033[31mError:\033[0m $failed deployment check(s) failed; snapshot and address were preserved for retry"
    return 1 2>/dev/null || exit 1
fi

if ! validate_snapshot "$airdropAddress"; then
    echo -e "\033[31mError:\033[0m Deployed Airdrop rejected a snapshot address or proof; files were preserved for retry"
    return 1 2>/dev/null || exit 1
fi
echo -e "\033[32m✓\033[0m Deployed Airdrop validated every snapshot address"

echo -e "\n[5/5] Record deployment"
temp_manifest="$snapshot_dir/.airdrop-deployment.$$.tmp"
manifest_network=$(printf '%s' "$target_network" | sed 's/\\/\\\\/g; s/"/\\"/g')
if ! printf '%s\n' \
    '{' \
    "  \"network\": \"$manifest_network\"," \
    "  \"targetChainId\": \"$CHAIN_ID\"," \
    "  \"airdropAddress\": \"$airdropAddress\"," \
    "  \"sourceChainId\": \"$SOURCE_CHAIN_ID\"," \
    "  \"sourceBlockNumber\": \"$SOURCE_BLOCK_NUMBER\"," \
    "  \"sourceBurnAddress\": \"$SOURCE_BURN\"," \
    "  \"merkleRoot\": \"$MERKLE_ROOT\"," \
    "  \"totalShare\": \"$TOTAL_SHARE\"," \
    '  "snapshot": "airdrop-snapshot.json"' \
    '}' >"$temp_manifest" \
    || ! mv "$temp_manifest" "$manifest"; then
    rm -f "$temp_manifest"
    echo -e "\033[31mError:\033[0m Failed to write airdrop-deployment.json"
    return 1 2>/dev/null || exit 1
fi

echo -e "\n\033[32m✓ Airdrop deployment completed:\033[0m $airdropAddress"
echo "Deployment manifest: $manifest"
