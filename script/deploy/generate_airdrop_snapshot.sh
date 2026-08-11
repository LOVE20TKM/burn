#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_ROOT="$REPO_ROOT/script/network"

source_network=${1:-}
target_network=${2:-}
source_dir="$NETWORK_ROOT/$source_network"
target_dir="$NETWORK_ROOT/$target_network"

if [ -z "$source_network" ] || [ -z "$target_network" ]; then
    echo "Usage: $0 <source-network> <target-network>"
    exit 1
fi
if [ ! -f "$source_dir/network.params" ] || [ ! -f "$source_dir/address.burn.params" ]; then
    echo "Error: source network.params or address.burn.params not found"
    exit 1
fi
if [ ! -d "$target_dir" ]; then
    echo "Error: target network directory not found"
    exit 1
fi

requested_block=${SOURCE_BLOCK_NUMBER:-}
unset RPC_URL CHAIN_ID burnAddress
set -a
source "$source_dir/network.params"
source "$source_dir/address.burn.params"
set +a

actual_chain_id=$(cast chain-id --rpc-url "${RPC_URL:-}" 2>/dev/null)
if [ -z "${RPC_URL:-}" ] || [[ ! "${CHAIN_ID:-}" =~ ^[0-9]+$ ]] || [ "$actual_chain_id" != "$CHAIN_ID" ]; then
    echo "Error: source RPC unavailable or chain id mismatch"
    exit 1
fi
if [[ ! "${burnAddress:-}" =~ ^0x[[:xdigit:]]{40}$ ]]; then
    echo "Error: source burnAddress is invalid"
    exit 1
fi
source_code=$(cast code "$burnAddress" --rpc-url "$RPC_URL" 2>/dev/null)
if [ -z "$source_code" ] || [ "$source_code" = "0x" ]; then
    echo "Error: source Burn has no contract code"
    exit 1
fi

source_block=${requested_block:-$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null)}
if [[ ! "$source_block" =~ ^[0-9]+$ ]] || [ "$source_block" -le 0 ]; then
    echo "Error: SOURCE_BLOCK_NUMBER must be a positive integer"
    exit 1
fi

snapshot_prefix="$CHAIN_ID-$(printf '%s' "$burnAddress" | tr '[:upper:]' '[:lower:]')-"
snapshot_id="$snapshot_prefix$source_block"
snapshot_root="$target_dir/airdrops"
snapshot_dir="$snapshot_root/$snapshot_id"
temp_dir="$snapshot_root/.$snapshot_id.$$.tmp"
snapshot="$temp_dir/airdrop-snapshot.json"
params="$temp_dir/airdrop.params"
pending_snapshots=()
for candidate in "$snapshot_root/$snapshot_prefix"*; do
    [ -d "$candidate" ] || continue
    [ -f "$candidate/airdrop-deployment.json" ] || pending_snapshots+=("$candidate")
done
if [ "${#pending_snapshots[@]}" -ne 0 ]; then
    echo "Error: Pending Airdrop snapshot already exists:"
    printf '  %s\n' "${pending_snapshots[@]}"
    exit 1
fi
if [ -e "$snapshot_dir" ]; then
    echo "Error: Airdrop snapshot already exists: $snapshot_dir"
    exit 1
fi
mkdir -p "$snapshot_root" || exit 1
mkdir "$temp_dir" || exit 1
trap 'rm -rf "$temp_dir"' EXIT

echo "[1/2] Generate snapshot from $source_network block $source_block"
cd "$REPO_ROOT" || exit 1
if ! SOURCE_CHAIN_ID="$CHAIN_ID" \
    SOURCE_BLOCK_NUMBER="$source_block" \
    SOURCE_BURN="$burnAddress" \
    SNAPSHOT_OUTPUT="$snapshot" \
    network="$target_network" \
    forge script script/GenerateAirdropSnapshot.s.sol \
        --rpc-url "$RPC_URL" \
        --fork-block-number "$source_block" \
        --force; then
    echo "Error: failed to generate Airdrop snapshot"
    exit 1
fi

json_value() {
    sed -nE "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*$/\1/p" "$snapshot"
}

snapshot_chain_id=$(json_value sourceChainId)
snapshot_block=$(json_value sourceBlockNumber)
snapshot_burn=$(json_value sourceBurnAddress)
merkle_root=$(json_value merkleRoot)
total_share=$(json_value totalShare)
if [ "$snapshot_chain_id" != "$CHAIN_ID" ] || [ "$snapshot_block" != "$source_block" ] \
    || [ "$(printf '%s' "$snapshot_burn" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$burnAddress" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "Error: generated snapshot source metadata mismatch"
    exit 1
fi
if [[ ! "$merkle_root" =~ ^0x[[:xdigit:]]{64}$ ]] \
    || [[ ! "$total_share" =~ ^[0-9]+$ ]] \
    || [ "$total_share" -le 0 ] \
    || [ "$total_share" -gt 1000000000000000000 ]; then
    echo "Error: generated snapshot root or totalShare is invalid"
    exit 1
fi

printf '%s\n' \
    "SOURCE_CHAIN_ID=$CHAIN_ID" \
    "SOURCE_BLOCK_NUMBER=$source_block" \
    "SOURCE_BURN=$burnAddress" \
    "MERKLE_ROOT=$merkle_root" \
    "TOTAL_SHARE=$total_share" >"$params"
mv "$temp_dir" "$snapshot_dir"

echo "[2/2] Snapshot configuration written"
echo "Snapshot: $snapshot_dir/airdrop-snapshot.json"
echo "Params:   $snapshot_dir/airdrop.params"
echo "After review: bash script/deploy/one_click_deploy_airdrop.sh $source_network $target_network"
