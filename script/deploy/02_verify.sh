#!/bin/bash

if [[ "$network" != thinkium70001* ]]; then
    echo "Skipping explorer verification for $network"
    return 0 2>/dev/null || exit 0
fi

if [ -z "$burnAddress" ]; then
    source "$network_dir/address.burn.params"
fi

forge verify-contract --chain-id "$CHAIN_ID" --verifier "$VERIFIER" --verifier-url "$VERIFIER_URL" \
    --rpc-url "$RPC_URL" \
    --guess-constructor-args "$burnAddress" src/Burn.sol:Burn
