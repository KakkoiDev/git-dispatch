#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/git-dispatch.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "Error: git-dispatch.sh not found at $SCRIPT" >&2
    exit 1
fi

# Set up git alias
chmod +x "$SCRIPT"
git config --global alias.dispatch "!bash $SCRIPT"
echo "Installed: git dispatch → $SCRIPT"
echo ""
echo "Usage:"
echo "  git dispatch help"
echo "  git dispatch split <source> --name <prefix> --base <base>"
echo "  git dispatch sync [source] [task]"
echo "  git dispatch status [source]"
echo "  git dispatch pr [source] [--push] [--dry-run]"
echo "  git dispatch tree [branch]"
echo "  git dispatch reset [source] [--branches] [--force]"
echo "  git dispatch hook install"
