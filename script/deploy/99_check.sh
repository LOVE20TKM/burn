#!/bin/bash

if [ -z "$burnAddress" ]; then
    source "$network_dir/address.burn.params"
fi

code=$(cast code "$burnAddress" --rpc-url "$RPC_URL" 2>/dev/null)
if [ -z "$burnAddress" ] || [ -z "$code" ] || [ "$code" = "0x" ]; then
    echo -e "\033[31mError:\033[0m No Burn contract code found"
    return 1 2>/dev/null || exit 1
fi

failed=0
check_equal "extensionCenter" "$EXTENSION_CENTER" "$(cast_call "$burnAddress" "extensionCenter()(address)")" || ((failed++))
check_equal "scopeTokenAddress" "$SCOPE_TOKEN" "$(cast_call "$burnAddress" "scopeTokenAddress()(address)")" || ((failed++))
check_equal "airdropTokenAddress" "${AIRDROP_TOKEN:-0x0000000000000000000000000000000000000000}" "$(cast_call "$burnAddress" "airdropTokenAddress()(address)")" || ((failed++))
check_equal "roundCount" "$ROUND_COUNT" "$(cast_call "$burnAddress" "roundCount()(uint256)")" || ((failed++))
check_equal "quotaMultiplier" "$QUOTA_MULTIPLIER" "$(cast_call "$burnAddress" "quotaMultiplier()(uint256)")" || ((failed++))

actual_start=$(cast_call "$burnAddress" "startRound()(uint256)")
actual_start="${actual_start%% *}"
check_equal "startRound" "$START_ROUND" "$actual_start" || ((failed++))
expected_end=$((START_ROUND + ROUND_COUNT - 1))
check_equal "endRound" "$expected_end" "$(cast_call "$burnAddress" "endRound()(uint256)")" || ((failed++))

normalize_array() {
    printf '%s' "$1" | tr -d '[][:space:]' | tr '[:upper:]' '[:lower:]'
}

actual_communities=$(normalize_array "$(cast_call "$burnAddress" "communities()(address[])")")
check_equal "communities" "$COMMUNITY_TOKENS" "$actual_communities" || ((failed++))

tokens="$COMMUNITY_TOKENS,"
weights="$COMMUNITY_WEIGHTS,"
while [ -n "$tokens" ] && [ -n "$weights" ]; do
    token="${tokens%%,*}"
    weight="${weights%%,*}"
    tokens="${tokens#*,}"
    weights="${weights#*,}"
    check_equal "communityWeight($token)" "$weight" "$(cast_call "$burnAddress" "communityWeight(address)(uint256)" "$token")" || ((failed++))
done

actual_factories=$(normalize_array "$(cast_call "$burnAddress" "supportedExtensionFactories()(address[])")")
check_equal "supportedExtensionFactories" "${SUPPORTED_EXTENSION_FACTORIES:-}" "$actual_factories" || ((failed++))

if [ "$failed" -ne 0 ]; then
    echo -e "\033[31m✗ $failed deployment check(s) failed\033[0m"
    return 1 2>/dev/null || exit 1
fi

echo -e "\033[32m✓ Burn deployment checks passed\033[0m"
