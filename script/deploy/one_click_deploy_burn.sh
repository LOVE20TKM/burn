#!/bin/bash

if [ -n "${ZSH_VERSION:-}" ]; then
    SCRIPT_PATH="$0"
else
    SCRIPT_PATH="${BASH_SOURCE[0]}"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || return 1 2>/dev/null || exit 1

echo -e "\n[1/4] Initialize $1"
source "$SCRIPT_DIR/00_init.sh" "$1" || return 1 2>/dev/null || exit 1

if [ "$network" = "anvil" ]; then
    echo -e "\n[Anvil] Complete scope token launch"
    source "$SCRIPT_DIR/00_prepare_anvil_scope.sh" || return 1 2>/dev/null || exit 1
fi

echo -e "\n[2/4] Deploy Burn"
source "$SCRIPT_DIR/01_deploy_burn.sh" || return 1 2>/dev/null || exit 1

echo -e "\n[3/4] Verify source"
source "$SCRIPT_DIR/02_verify.sh" || echo -e "\033[33mWarning:\033[0m Explorer verification failed"

echo -e "\n[4/4] Check deployment"
source "$SCRIPT_DIR/99_check.sh" || return 1 2>/dev/null || exit 1

echo -e "\n\033[32m✓ Burn deployment completed:\033[0m $burnAddress"
