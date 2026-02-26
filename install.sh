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
echo "  git dispatch init [--base <branch>] [--prefix <str>] [--mode <independent|stacked>]"
echo "  git dispatch apply [--dry-run]"
echo "  git dispatch cherry-pick --from <source|id> --to <source|id>"
echo "  git dispatch push --from <id|all|source> [--dry-run]"
echo "  git dispatch status"
echo "  git dispatch reset [--force]"
echo "  git dispatch help"
