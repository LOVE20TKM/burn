#!/bin/bash

if [ "$network" != "anvil" ]; then
    return 0 2>/dev/null || exit 0
fi

launch_address=$(cast_call "$EXTENSION_CENTER" "launchAddress()(address)") || return 1 2>/dev/null || exit 1
parent_token=$(cast_call "$SCOPE_TOKEN" "parentTokenAddress()(address)") || return 1 2>/dev/null || exit 1
launch_info_signature="launchInfo(address)((address,uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256))"
launch_info=$(cast_call "$launch_address" "$launch_info_signature" "$SCOPE_TOKEN") || return 1 2>/dev/null || exit 1
launch_fields=$(printf '%s' "$launch_info" | sed 's/^(//;s/)$//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
has_ended=$(printf '%s\n' "$launch_fields" | sed -n '8p')

if [ "$has_ended" = "true" ]; then
    echo -e "\033[32m✓\033[0m Scope token launch already completed"
    return 0 2>/dev/null || exit 0
fi

fundraising_goal=$(printf '%s\n' "$launch_fields" | sed -n '2p' | awk '{print $1}')
second_half_min_blocks=$(printf '%s\n' "$launch_fields" | sed -n '3p' | awk '{print $1}')
total_contributed=$(printf '%s\n' "$launch_fields" | sed -n '10p' | awk '{print $1}')
half_goal=$((fundraising_goal / 2))
first_amount=0
if [ "$total_contributed" -lt "$half_goal" ]; then
    first_amount=$((half_goal - total_contributed))
fi

remaining_amount=$((fundraising_goal - total_contributed - first_amount))
if [ "$remaining_amount" -le 0 ]; then
    remaining_amount=1
fi
funding_amount=$((first_amount + remaining_amount))

anvil_send() {
    local address=$1
    local signature=$2
    shift 2
    cast send "$address" "$signature" "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --legacy
}

anvil_send "$parent_token" "deposit()" --value "$funding_amount" || return 1 2>/dev/null || exit 1
anvil_send "$parent_token" "approve(address,uint256)(bool)" "$launch_address" "$funding_amount" || return 1 2>/dev/null || exit 1

if [ "$first_amount" -gt 0 ]; then
    anvil_send "$launch_address" "contribute(address,uint256,address)" "$SCOPE_TOKEN" "$first_amount" "$ACCOUNT_ADDRESS" \
        || return 1 2>/dev/null || exit 1
fi

cast rpc anvil_mine "$second_half_min_blocks" --rpc-url "$RPC_URL" >/dev/null \
    || return 1 2>/dev/null || exit 1
anvil_send "$launch_address" "contribute(address,uint256,address)" "$SCOPE_TOKEN" "$remaining_amount" "$ACCOUNT_ADDRESS" \
    || return 1 2>/dev/null || exit 1

launch_info=$(cast_call "$launch_address" "$launch_info_signature" "$SCOPE_TOKEN") || return 1 2>/dev/null || exit 1
has_ended=$(printf '%s' "$launch_info" | sed 's/^(//;s/)$//' | tr ',' '\n' | sed -n '8p' | tr -d '[:space:]')
if [ "$has_ended" != "true" ]; then
    echo -e "\033[31mError:\033[0m Failed to complete scope token launch"
    return 1 2>/dev/null || exit 1
fi

echo -e "\033[32m✓\033[0m Scope token launch completed"
