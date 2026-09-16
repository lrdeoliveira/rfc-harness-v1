#!/usr/bin/env bash
#
# init-status.sh
#
# Painel da cadeia /init: presenca, freshness (stamp sha256) e stack observada.
# Nao escreve nada no projeto — e um leitor puro, o equivalente do
# ralph-watch.sh para o bootstrap.
#
# Uso:
#   ./init-status.sh [caminho-do-repo]         painel colorido no terminal
#   ./init-status.sh --plain [caminho]         markdown para o roteador /init
#   ./init-status.sh --no-color [caminho]
#
# Exit:
#   0  cadeia completa e fresh
#   1  falta artefato, stale, ou freshness desconhecida
#   2  uso / diretorio invalido
#
# O --plain e o que o /init consome: tabela + proximo passo. O painel colorido
# e para o desenvolvedor acompanhar de outro terminal enquanto o /init roda.

# macOS /bin/bash e 3.2; declare -A exige 4+.
if { [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; } && \
   { [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; }; then
  _reexec=""
  for _cand in \
    "${RALPH_BASH:-}" \
    /opt/homebrew/bin/bash \
    /usr/local/bin/bash \
    /opt/local/bin/bash
  do
    [ -n "${_cand}" ] && [ -x "${_cand}" ] || continue
    if "${_cand}" -c 'test "${BASH_VERSINFO[0]}" -ge 4' 2>/dev/null; then
      _reexec="${_cand}"
      break
    fi
  done
  if [ -n "${_reexec}" ]; then
    exec "${_reexec}" "$0" "$@"
  fi
  echo "init-status.sh requer Bash 4+ (atual: ${BASH_VERSION:-desconhecido})." >&2
  echo "No macOS: brew install bash" >&2
  exit 2
fi
unset _reexec _cand 2>/dev/null || true

set -u

PLAIN=false
USE_COLOR=true
REPO="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plain)     PLAIN=true; shift ;;
    --no-color)  USE_COLOR=false; shift ;;
    --color)     USE_COLOR=true; shift ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    *)           REPO="$1"; shift ;;
  esac
done

if [ ! -d "$REPO" ]; then
  echo "init-status.sh: diretorio nao encontrado: $REPO" >&2
  exit 2
fi

# Resolve o detector: ao lado deste script (plugin ou checkout).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/detect-project.sh"

if $PLAIN || [ ! -t 1 ]; then
  USE_COLOR=false
fi

if $USE_COLOR; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_CYAN=$'\033[38;5;81m'; C_GREEN=$'\033[38;5;77m'; C_YELLOW=$'\033[38;5;221m'
  C_RED=$'\033[38;5;203m'; C_GREY=$'\033[38;5;245m'; C_WHITE=$'\033[38;5;255m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GREY=""; C_WHITE=""
fi

cd "$REPO" || exit 2
ROOT="$(pwd)"
INIT_DIR="$ROOT/.spec/init"

# status por artefato: absent | present | stale | nostamp | optional-absent | optional-present
declare -A ST
declare -a STALE_LINES=()

artifact_status() {
  local name="$1"
  local file="$INIT_DIR/$name.md"
  if [ ! -f "$file" ]; then
    printf '%s' "absent"
    return
  fi
  local line3
  line3=$(sed -n '3p' "$file" 2>/dev/null || true)
  if ! grep -qE '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}' <<< "$line3"; then
    # cabeca da cadeia (project-description) nao carrega stamp — present puro
    if [ "$name" = "project-description" ]; then
      printf '%s' "present"
    else
      printf '%s' "nostamp"
    fi
    return
  fi
  local pair fname expected actual
  local stale=0
  for pair in $(printf '%s' "$line3" | grep -oE '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}'); do
    fname="${pair%%@*}"
    expected="${pair##*:}"
    if [ ! -f "$INIT_DIR/$fname" ]; then
      STALE_LINES+=("stale: $name.md predates current $fname (arquivo ausente)")
      stale=1
      continue
    fi
    actual=$(sha256sum "$INIT_DIR/$fname" | cut -c1-12)
    if [ "$actual" != "$expected" ]; then
      STALE_LINES+=("stale: $name.md predates current $fname")
      stale=1
    fi
  done
  if [ "$stale" -eq 1 ]; then
    printf '%s' "stale"
  else
    printf '%s' "present"
  fi
}

ST[project-description]=$(artifact_status project-description)
ST[user-stories]=$(artifact_status user-stories)
ST[database-schema]=$(artifact_status database-schema)
ST[project-phases]=$(artifact_status project-phases)
if [ -d "$INIT_DIR/design" ]; then
  ST[design]="optional-present"
else
  ST[design]="optional-absent"
fi

# Proximo passo — mesma ordem do commands/init.md
NEXT_CMD=""
NEXT_WHY=""
CHAIN_OK=1

first_absent=""
first_stale=""
first_nostamp=""
for name in project-description user-stories database-schema project-phases; do
  case "${ST[$name]}" in
    absent)  [ -z "$first_absent" ] && first_absent="$name" ;;
    stale)   [ -z "$first_stale" ] && first_stale="$name" ;;
    nostamp) [ -z "$first_nostamp" ] && first_nostamp="$name" ;;
  esac
done

if [ -n "$first_absent" ]; then
  NEXT_CMD="/init:$first_absent"
  NEXT_WHY="primeiro artefato ausente na ordem da cadeia"
  CHAIN_OK=1
elif [ -n "$first_stale" ]; then
  NEXT_CMD="/init:$first_stale"
  NEXT_WHY="primeiro artefato stale — re-run e upsert-safe (entrevista so os deltas)"
  CHAIN_OK=1
else
  NEXT_CMD=""
  NEXT_WHY="Chain complete and fresh — nothing to do."
  CHAIN_OK=0
  if [ -n "$first_nostamp" ]; then
    NEXT_WHY="Chain complete. Freshness of $first_nostamp.md can't be verified until its command is re-run once."
  fi
fi

# Stack observada
STACK_SUMMARY="—"
STACK_PLAIN=""
if [ -x "$DETECT" ]; then
  STACK_PLAIN=$("$DETECT" --plain "$ROOT" 2>/dev/null || true)
  STACK_SUMMARY=$("$DETECT" --machine "$ROOT" 2>/dev/null | sed -n 's/^SUMMARY=//p' || true)
  [ -z "$STACK_SUMMARY" ] && STACK_SUMMARY="—"
fi

status_label() {
  case "$1" in
    present)           printf '%s✓ present%s' "$C_GREEN" "$C_RESET" ;;
    stale)             printf '%s! stale%s' "$C_YELLOW" "$C_RESET" ;;
    nostamp)           printf '%s? present (no stamp)%s' "$C_YELLOW" "$C_RESET" ;;
    absent)            printf '%s· absent%s' "$C_GREY" "$C_RESET" ;;
    optional-present)  printf '%spresent (manual)%s' "$C_GREEN" "$C_RESET" ;;
    optional-absent)   printf '%sabsent (optional)%s' "$C_GREY" "$C_RESET" ;;
    *)                 printf '%s%s%s' "$C_GREY" "$1" "$C_RESET" ;;
  esac
}

status_plain() {
  case "$1" in
    present)           printf 'present' ;;
    stale)             printf 'stale' ;;
    nostamp)           printf 'present (no stamp)' ;;
    absent)            printf 'absent' ;;
    optional-present)  printf 'present (manual)' ;;
    optional-absent)   printf 'absent (optional)' ;;
    *)                 printf '%s' "$1" ;;
  esac
}

if $PLAIN; then
  echo "# Init chain"
  echo
  echo "| Artifact | Status |"
  echo "|---|---|"
  echo "| \`.spec/init/project-description.md\` | $(status_plain "${ST[project-description]}") |"
  echo "| \`.spec/init/user-stories.md\` | $(status_plain "${ST[user-stories]}") |"
  echo "| \`.spec/init/database-schema.md\` | $(status_plain "${ST[database-schema]}") |"
  echo "| \`.spec/init/project-phases.md\` | $(status_plain "${ST[project-phases]}") |"
  echo "| \`.spec/init/design/\` | $(status_plain "${ST[design]}") |"
  echo
  if [ ${#STALE_LINES[@]} -gt 0 ]; then
    echo "## Stale"
    echo
    local_line=""
    for local_line in "${STALE_LINES[@]}"; do
      echo "- \`$local_line\`"
    done
    echo
  fi
  echo "## Stack observada"
  echo
  if [ -n "$STACK_PLAIN" ]; then
    printf '%s\n' "$STACK_PLAIN"
  else
    echo "- detector ausente — inspecione manifests na mao"
  fi
  echo
  echo "## Next step"
  echo
  if [ -n "$NEXT_CMD" ]; then
    echo "Invoke \`$NEXT_CMD\` — $NEXT_WHY"
  else
    echo "$NEXT_WHY"
  fi
  exit "$CHAIN_OK"
fi

# Painel humano
project=$(basename "$ROOT")
printf '\n%s%sINIT%s  %s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM$project$C_RESET"
printf '%sStack:%s %s\n' "$C_CYAN" "$C_RESET" "$STACK_SUMMARY"
if [ -n "$STACK_PLAIN" ]; then
  printf '%s\n' "$STACK_PLAIN" | sed "s/^/${C_GREY}/;s/\$/${C_RESET}/"
fi
echo

printf '%s┌─ CADEIA .spec/init/ ─────────────────────────────────────────┐%s\n' "$C_CYAN" "$C_RESET"
row() {
  local id="$1" name="$2" st="$3"
  printf '%s│%s  %s%-22s%s  %-36s %s│%s\n' \
    "$C_CYAN" "$C_RESET" \
    "$C_WHITE" "$id $name" "$C_RESET" \
    "$(status_label "$st")" \
    "$C_CYAN" "$C_RESET"
}
row "1" "project-description.md" "${ST[project-description]}"
row "2" "user-stories.md"        "${ST[user-stories]}"
row "3" "database-schema.md"     "${ST[database-schema]}"
row "4" "project-phases.md"      "${ST[project-phases]}"
row "—" "design/"                "${ST[design]}"
printf '%s└──────────────────────────────────────────────────────────────┘%s\n' "$C_CYAN" "$C_RESET"

if [ ${#STALE_LINES[@]} -gt 0 ]; then
  echo
  local_line=""
  for local_line in "${STALE_LINES[@]}"; do
    printf '  %s%s%s\n' "$C_YELLOW" "$local_line" "$C_RESET"
  done
fi

echo
if [ -n "$NEXT_CMD" ]; then
  printf '%sPróximo:%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$NEXT_CMD" "$C_RESET"
  printf '%s        %s%s\n' "$C_GREY" "$NEXT_WHY" "$C_RESET"
else
  printf '%s%s%s\n' "$C_GREEN" "$NEXT_WHY" "$C_RESET"
fi
echo

exit "$CHAIN_OK"
