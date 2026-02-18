#!/bin/bash
set -euo pipefail

REPO="KakkoiDev/git-dispatch"
BRANCH="master"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
INSTALL_DIR="$HOME/.git-dispatch"

mkdir -p "$INSTALL_DIR/hooks"

echo "Downloading git-dispatch..."
curl -fsSL "$BASE/git-dispatch.sh" -o "$INSTALL_DIR/git-dispatch.sh"
curl -fsSL "$BASE/hooks/commit-msg" -o "$INSTALL_DIR/hooks/commit-msg"
chmod +x "$INSTALL_DIR/git-dispatch.sh" "$INSTALL_DIR/hooks/commit-msg"

git config --global alias.dispatch "!bash $INSTALL_DIR/git-dispatch.sh"
echo "Installed: git dispatch → $INSTALL_DIR/git-dispatch.sh"
echo ""
echo "Usage:"
echo "  git dispatch help"
