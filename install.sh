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
echo "What this installer did:"
echo "  - Added global git alias: git dispatch"
echo "  - Made executable: $SCRIPT"
echo ""
echo "What this installer did NOT do:"
echo "  - Did not install/update AI agent or skill files"
echo ""
echo "Usage:"
echo "  git dispatch init [--base <branch>] [--target-pattern <pattern>] [--mode <independent|stacked>]"
echo "  git dispatch apply [--dry-run]"
echo "  git dispatch cherry-pick --from <source|id> --to <source|id>"
echo "  git dispatch push --from <id|all|source> [--dry-run]"
echo "  git dispatch status"
echo "  git dispatch reset [--force]"
echo "  git dispatch help"
echo ""
echo "Optional AI setup:"
echo "  Claude (skills + agent):"
echo "    mkdir -p ~/.claude/skills/git-dispatch ~/.claude/agents"
echo "    cp \"$SCRIPT_DIR/SKILL.md\" ~/.claude/skills/git-dispatch/SKILL.md"
echo "    cp \"$SCRIPT_DIR/AGENTS.md\" ~/.claude/agents/git-dispatch.md"
echo ""
echo "  Codex (skills + repo agent file):"
echo "    mkdir -p \"\${CODEX_HOME:-$HOME/.codex}/skills/git-dispatch\""
echo "    cp \"$SCRIPT_DIR/SKILL.md\" \"\${CODEX_HOME:-$HOME/.codex}/skills/git-dispatch/SKILL.md\""
echo "    cp \"$SCRIPT_DIR/AGENTS.md\" /path/to/your/project/AGENTS.md"
echo ""
echo "  Gemini (repo instructions):"
echo "    cp \"$SCRIPT_DIR/AGENTS.md\" /path/to/your/project/AGENTS.md"
echo "    cp \"$SCRIPT_DIR/SKILL.md\" /path/to/your/project/GEMINI.md"
