#!/usr/bin/env bash
# Instala a versão canônica dos commands/agents em Cursor, OpenCode, Codex e SGM.
set -euo pipefail
HARNESS="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(tr -d '[:space:]' < "$HARNESS/VERSION")"
CMD="$HARNESS/commands"
AGT="$HARNESS/agents"

sync_tree() {
  local dest="$1"
  mkdir -p "$dest"
  rsync -a "$CMD/" "$dest/"
}

echo "rfc-harness $VER → hosts"

# Cursor (user-wide)
sync_tree "$HOME/.cursor/commands"
mkdir -p "$HOME/.cursor/agents"
rsync -a "$AGT/" "$HOME/.cursor/agents/"
echo "  Cursor     ~/.cursor/commands + ~/.cursor/agents"

# OpenCode (MiniMax)
sync_tree "$HOME/.config/opencode/commands"
mkdir -p "$HOME/.config/opencode/agents"
rsync -a "$AGT/" "$HOME/.config/opencode/agents/"
echo "  OpenCode   ~/.config/opencode/commands + agents"

# Codex
sync_tree "$HOME/.codex/prompts"
echo "  Codex      ~/.codex/prompts"

# SGM
SGM="/Volumes/M5SSD/Projetos_Novos/SGM"
if [[ -d "$SGM" ]]; then
  sync_tree "$SGM/.cursor/commands"
  mkdir -p "$SGM/.cursor/agents"
  rsync -a "$AGT/" "$SGM/.cursor/agents/"
  echo "  SGM        $SGM/.cursor/commands + agents"
fi

echo "Pronto. Claude Code: plugin rfc-harness@$VER (marketplace local)."
