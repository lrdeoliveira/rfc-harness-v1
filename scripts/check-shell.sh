#!/usr/bin/env bash
#
# check-shell.sh — sanidade dos scripts de shell do harness.
#
#   1. bash -n em todo scripts/*.sh (sempre roda; so precisa de bash)
#   2. shellcheck quando disponivel (dev-only; ausencia nao falha o check)
#
# Uso: scripts/check-shell.sh   (de qualquer lugar; exit 0 = limpo)

set -u
cd "$(dirname "$0")/.." || exit 1

FAIL=0
FILES=(scripts/*.sh)

echo "== bash -n (${#FILES[@]} arquivos)"
for f in "${FILES[@]}"; do
  if bash -n "$f" 2>/dev/null; then
    echo "  ok    $f"
  else
    echo "  ERRO  $f"
    bash -n "$f" 2>&1 | sed 's/^/        /'
    FAIL=1
  fi
done

echo
if command -v shellcheck > /dev/null 2>&1; then
  echo "== shellcheck"
  for f in "${FILES[@]}"; do
    if shellcheck -x "$f"; then
      echo "  ok    $f"
    else
      FAIL=1
    fi
  done
else
  echo "== shellcheck AUSENTE — pulado (instale: apt install shellcheck)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK: shell limpo."
else
  echo "FALHA: corrija os problemas acima."
fi
exit "$FAIL"
