#!/usr/bin/env bash
#
# detect-project.sh
#
# Inspeciona o repositorio e emite fatos OBSERVADOS: stack, framework, runner
# de teste, infra, branch e se existe um grafo de codigo (graphify).
#
# Nunca le .env (principio do harness: sem segredos). Ambiente vem so de
# variaveis ja exportadas no shell ou da presenca de arquivos (.env.example,
# .env.production, …), nunca do conteudo deles.
#
# Uso:
#   ./detect-project.sh [caminho-do-repo]          relatorio humano
#   ./detect-project.sh --machine [caminho]        KEY=value (ralph / init-status)
#   ./detect-project.sh --plain [caminho]          markdown compacto (/init)
#
# Exit 0 sempre que o diretorio existir — "nada detectado" e um resultado
# valido (repo vazio / pre-codigo), nao um erro.

set -u

MACHINE=false
PLAIN=false
TARGET="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine) MACHINE=true; shift ;;
    --plain)   PLAIN=true; shift ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) TARGET="$1"; shift ;;
  esac
done

if [ ! -d "$TARGET" ]; then
  echo "detect-project.sh: diretorio nao encontrado: $TARGET" >&2
  exit 1
fi

cd "$TARGET" || exit 1

STACKS=()
FRAMEWORKS=()
TEST_RUNNERS=()
PACKAGE_MANAGERS=()
INFRA=()
ENV_NAME="development"
ENV_SOURCE="default (workspace local)"
BRANCH=""
DIRTY="0"
GRAPH="absent"

has() { [ -f "$1" ]; }
has_any() { local f; for f in "$@"; do [ -f "$f" ] && return 0; done; return 1; }
json_has() { [ -f "$1" ] && grep -qF "$2" "$1"; }

# ---------------------------------------------------------------------------
# Ambiente — variaveis ja no shell, depois so a PRESENCA de arquivos
# ---------------------------------------------------------------------------

for var in APP_ENV NODE_ENV ENVIRONMENT ENV STAGE; do
  eval "raw=\${$var:-}"
  [ -n "$raw" ] || continue
  val=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  if [[ "$val" =~ (prod|production|prd|live) ]]; then
    ENV_NAME="production"; ENV_SOURCE="variavel $var"; break
  elif [[ "$val" =~ (stage|staging|homolog|homologacao|uat|qa) ]]; then
    ENV_NAME="staging"; ENV_SOURCE="variavel $var"; break
  elif [[ "$val" =~ (dev|development|local|test|testing) ]]; then
    ENV_NAME="development"; ENV_SOURCE="variavel $var"; break
  fi
done

if [ "$ENV_SOURCE" = "default (workspace local)" ]; then
  if has .env.production; then
    ENV_NAME="production"
    ENV_SOURCE="arquivo .env.production presente (conteudo nao lido)"
  elif has_any .env.staging .env.homolog .env.homologacao; then
    ENV_NAME="staging"
    ENV_SOURCE="arquivo .env.staging/.env.homolog presente (conteudo nao lido)"
  elif has .env.example; then
    ENV_SOURCE="default; .env.example presente (nomes, sem valores)"
  fi
fi

# ---------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
  DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
fi

# ---------------------------------------------------------------------------
# Stacks
# ---------------------------------------------------------------------------

if has composer.json; then
  STACKS+=("PHP")
  PACKAGE_MANAGERS+=("composer")
  if json_has composer.json 'laravel/framework' || has artisan; then
    FRAMEWORKS+=("Laravel")
  fi
  if json_has composer.json 'filament/filament'; then
    FRAMEWORKS+=("Filament")
  fi
  if grep -q '"symfony/' composer.json 2>/dev/null; then
    FRAMEWORKS+=("Symfony")
  fi
  if has_any phpunit.xml phpunit.xml.dist; then
    TEST_RUNNERS+=("phpunit")
  fi
  if has tests/Pest.php || json_has composer.json 'pestphp/pest'; then
    TEST_RUNNERS+=("pest")
  fi
fi

if has package.json; then
  STACKS+=("Node.js")
  if has pnpm-lock.yaml; then PACKAGE_MANAGERS+=("pnpm")
  elif has yarn.lock; then PACKAGE_MANAGERS+=("yarn")
  elif has_any bun.lockb bun.lock; then PACKAGE_MANAGERS+=("bun")
  else PACKAGE_MANAGERS+=("npm")
  fi
  has tsconfig.json && STACKS+=("TypeScript")
  json_has package.json '"next"' && FRAMEWORKS+=("Next.js")
  json_has package.json '"nuxt"' && FRAMEWORKS+=("Nuxt")
  json_has package.json '"react"' && FRAMEWORKS+=("React")
  json_has package.json '"vue"' && FRAMEWORKS+=("Vue.js")
  json_has package.json '"@nestjs/core"' && FRAMEWORKS+=("NestJS")
  json_has package.json '"livewire"' && FRAMEWORKS+=("Livewire")
  if has_any vitest.config.ts vitest.config.js || json_has package.json '"vitest"'; then
    TEST_RUNNERS+=("vitest")
  fi
  if has_any jest.config.js jest.config.ts || json_has package.json '"jest"'; then
    TEST_RUNNERS+=("jest")
  fi
  json_has package.json '"playwright"' && TEST_RUNNERS+=("playwright")
fi

if has_any pyproject.toml requirements.txt Pipfile setup.py; then
  STACKS+=("Python")
  if has poetry.lock; then PACKAGE_MANAGERS+=("poetry")
  elif has Pipfile.lock; then PACKAGE_MANAGERS+=("pipenv")
  elif has uv.lock; then PACKAGE_MANAGERS+=("uv")
  else PACKAGE_MANAGERS+=("pip")
  fi
  if has pyproject.toml; then
    grep -qi 'fastapi' pyproject.toml 2>/dev/null && FRAMEWORKS+=("FastAPI")
    grep -qi 'django' pyproject.toml 2>/dev/null && FRAMEWORKS+=("Django")
    grep -qi 'flask' pyproject.toml 2>/dev/null && FRAMEWORKS+=("Flask")
  fi
  if has manage.py; then FRAMEWORKS+=("Django"); fi
  if has_any pytest.ini conftest.py || { has pyproject.toml && grep -q 'pytest' pyproject.toml; }; then
    TEST_RUNNERS+=("pytest")
  fi
fi

if has go.mod; then
  STACKS+=("Go")
  PACKAGE_MANAGERS+=("go modules")
  TEST_RUNNERS+=("go test")
fi

if has Cargo.toml; then
  STACKS+=("Rust")
  PACKAGE_MANAGERS+=("cargo")
  TEST_RUNNERS+=("cargo test")
fi

if has Gemfile; then
  STACKS+=("Ruby")
  PACKAGE_MANAGERS+=("bundler")
  grep -qF 'rails' Gemfile 2>/dev/null && FRAMEWORKS+=("Rails")
fi

if has_any pom.xml build.gradle build.gradle.kts; then
  STACKS+=("Java")
  has pom.xml && PACKAGE_MANAGERS+=("maven")
  has_any build.gradle build.gradle.kts && PACKAGE_MANAGERS+=("gradle")
fi

# ---------------------------------------------------------------------------
# Infra
# ---------------------------------------------------------------------------

has Dockerfile && INFRA+=("Dockerfile")
if has_any docker-compose.yml docker-compose.yaml compose.yaml compose.yml; then
  INFRA+=("Docker Compose")
fi
if has artisan && { [ -x vendor/bin/sail ] || json_has composer.json 'laravel/sail'; }; then
  INFRA+=("Laravel Sail")
fi
[ -d .devcontainer ] && INFRA+=("Devcontainer")

# Grafo de codigo (Graphify) — opcional; so reporta presenca. Nao e dependencia.
if has graphify-out/graph.json; then
  GRAPH="graphify-out/graph.json"
fi

# ---------------------------------------------------------------------------
# Formatacao
# ---------------------------------------------------------------------------

join_csv() {
  if [ "$#" -eq 0 ]; then
    printf '%s' ""
    return
  fi
  local IFS=', '
  printf '%s' "$*"
}

STACK_CSV=$(join_csv "${STACKS[@]+"${STACKS[@]}"}")
FRAMEWORK_CSV=$(join_csv "${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"}")
TEST_CSV=$(join_csv "${TEST_RUNNERS[@]+"${TEST_RUNNERS[@]}"}")
PKG_CSV=$(join_csv "${PACKAGE_MANAGERS[@]+"${PACKAGE_MANAGERS[@]}"}")
INFRA_CSV=$(join_csv "${INFRA[@]+"${INFRA[@]}"}")

SUMMARY="$STACK_CSV"
if [ -n "$FRAMEWORK_CSV" ]; then
  if [ -n "$SUMMARY" ]; then SUMMARY="$SUMMARY + $FRAMEWORK_CSV"
  else SUMMARY="$FRAMEWORK_CSV"
  fi
fi
[ -z "$SUMMARY" ] && SUMMARY="—"

dash() { [ -n "$1" ] && printf '%s' "$1" || printf '—'; }

if $MACHINE; then
  printf 'STACK=%s\n' "$STACK_CSV"
  printf 'FRAMEWORKS=%s\n' "$FRAMEWORK_CSV"
  printf 'TEST_RUNNERS=%s\n' "$TEST_CSV"
  printf 'PACKAGE_MANAGERS=%s\n' "$PKG_CSV"
  printf 'INFRA=%s\n' "$INFRA_CSV"
  printf 'ENV=%s\n' "$ENV_NAME"
  printf 'ENV_SOURCE=%s\n' "$ENV_SOURCE"
  printf 'BRANCH=%s\n' "$BRANCH"
  printf 'DIRTY=%s\n' "$DIRTY"
  printf 'GRAPH=%s\n' "$GRAPH"
  printf 'SUMMARY=%s\n' "$SUMMARY"
  exit 0
fi

if $PLAIN; then
  printf -- '- **Stack (OBSERVED):** %s\n' "$(dash "$SUMMARY")"
  printf -- '- **Test runners (OBSERVED):** %s\n' "$(dash "$TEST_CSV")"
  printf -- '- **Package managers (OBSERVED):** %s\n' "$(dash "$PKG_CSV")"
  printf -- '- **Infra (OBSERVED):** %s\n' "$(dash "$INFRA_CSV")"
  printf -- '- **Env:** %s — %s\n' "$ENV_NAME" "$ENV_SOURCE"
  printf -- '- **Branch:** %s (%s arquivos sujos)\n' "$(dash "$BRANCH")" "$DIRTY"
  if [ "$GRAPH" != "absent" ]; then
    printf -- '- **Grafo de codigo (OBSERVED):** `%s` — consulte antes de varrer o repo\n' "$GRAPH"
  else
    printf -- '- **Grafo de codigo:** ausente\n'
  fi
  exit 0
fi

echo "=== Stack e ambiente (fatos OBSERVED) ==="
echo "Diretorio:  $(pwd)"
echo "Quando:     $(date '+%Y-%m-%d %H:%M:%S')"
echo
echo "Stack:              $(dash "$SUMMARY")"
echo "Linguagens:         $(dash "$STACK_CSV")"
echo "Frameworks:         $(dash "$FRAMEWORK_CSV")"
echo "Gerenciadores:      $(dash "$PKG_CSV")"
echo "Runners de teste:   $(dash "$TEST_CSV")"
echo "Infra:              $(dash "$INFRA_CSV")"
echo "Ambiente:           $ENV_NAME"
echo "Evidencia do env:   $ENV_SOURCE"
echo "Branch:             $(dash "$BRANCH")"
echo "Arquivos sujos:     $DIRTY"
echo "Grafo (graphify):   $GRAPH"
echo
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  echo "Aviso: branch $BRANCH — ralph commita por fase; prefira uma branch descartavel."
fi
echo "========================================"
