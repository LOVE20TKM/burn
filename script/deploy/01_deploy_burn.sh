#!/bin/bash

if [ -n "${ZSH_VERSION:-}" ]; then
    SCRIPT_PATH="$0"
else
    SCRIPT_PATH="${BASH_SOURCE[0]}"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || return 1 2>/dev/null || exit 1

if [ -z "$RPC_URL" ]; then
    echo -e "\033[31mError:\033[0m Environment not initialized"
    return 1 2>/dev/null || exit 1
fi

forge_script script/DeployBurn.s.sol:DeployBurn --sig "run()"
if [ $? -ne 0 ]; then
    echo -e "\033[31m✗\033[0m Failed to deploy Burn"
    return 1 2>/dev/null || exit 1
fi

unset burnAddress
if ! source "$network_dir/address.burn.params"; then
    echo -e "\033[31m✗\033[0m Failed to read address.burn.params"
    return 1 2>/dev/null || exit 1
fi
if [ -z "${burnAddress:-}" ]; then
    echo -e "\033[31m✗\033[0m burnAddress is empty after deploy"
    return 1 2>/dev/null || exit 1
fi
if [[ ! "$burnAddress" =~ ^0x[[:xdigit:]]{40}$ ]]; then
    echo -e "\033[31m✗\033[0m burnAddress is invalid after deploy"
    return 1 2>/dev/null || exit 1
fi
echo -e "\033[32m✓\033[0m Burn deployed at: $burnAddress"
