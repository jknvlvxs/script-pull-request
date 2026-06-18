#!/bin/bash

set -e

HOTFIX=false
DRAFT=false
DIFF=false
DIFF_BRANCH=""
INTERACTIVE=false
LIST_MODELS=false
EXTRA_CONTEXT=""

# Endpoint da Generative Language API (usada diretamente via curl quando há API key).
API_BASE="https://generativelanguage.googleapis.com/v1beta"

# Modelo padrão. Pode ser sobrescrito via env GEMINI_MODEL, flag --model ou menu interativo.
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-pro}"

# Carrega variáveis de um arquivo .env (KEY=VALUE por linha), sem sobrescrever
# o que já existe no ambiente (env real tem precedência sobre o .env).
load_env_file() {
  local file="$1" line key val
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    line="${line#export }"
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    [ -z "$key" ] && continue
    # remove aspas externas (simples ou duplas)
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    if [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done < "$file"
}

# Procura o .env ao lado do script (acompanha a ferramenta), com override opcional
# via GENERATE_PR_ENV_FILE.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
load_env_file "${GENERATE_PR_ENV_FILE:-$SCRIPT_DIR/.env}"

# Resolução da API key (NUNCA hardcode aqui — este arquivo é versionado):
#   1. env GEMINI_API_KEY (inclui valores vindos do .env)
#   2. arquivo ~/.config/generate_pr/api_key (recomendado: chmod 600)
# Sem key, o script usa o gemini CLI como fallback.
API_KEY_FILE="$HOME/.config/generate_pr/api_key"
resolve_api_key() {
  if [ -n "$GEMINI_API_KEY" ]; then
    printf '%s' "$GEMINI_API_KEY"
  elif [ -f "$API_KEY_FILE" ]; then
    head -n1 "$API_KEY_FILE" | tr -d '[:space:]'
  fi
}
GEMINI_API_KEY_RESOLVED=$(resolve_api_key)

# Lista modelos da API que suportam generateContent (apenas família gemini).
list_models() {
  local key="$1"
  curl -s -m 20 -H "x-goog-api-key: $key" "$API_BASE/models" \
    | jq -r '.models[]? | select(.supportedGenerationMethods[]? == "generateContent") | .name' \
    | sed 's@models/@@' \
    | grep -E '^gemini' \
    | sort || true
}

# Gera conteúdo chamando a API REST diretamente (evita o roteador interno do gemini CLI).
generate_via_rest() {
  local prompt="$1" key="$2" model="$3"
  local req resp text

  req=$(jq -n --arg t "$prompt" '{contents:[{parts:[{text:$t}]}]}')

  resp=$(printf '%s' "$req" | curl -s -m 120 \
    -H "Content-Type: application/json" \
    -H "x-goog-api-key: $key" \
    -X POST -d @- \
    "$API_BASE/models/$model:generateContent")

  if printf '%s' "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "   ⚠️ API: $(printf '%s' "$resp" | jq -r '.error.message // "erro desconhecido"')" >&2
    return 1
  fi

  text=$(printf '%s' "$resp" | jq -r '[.candidates[0].content.parts[]? | select(.thought != true) | .text] | join("")')

  if [ -z "$text" ] || [ "$text" = "null" ]; then
    return 1
  fi

  printf '%s' "$text"
}

# Sem argumentos + terminal interativo => entra no modo interativo por padrão
if [ $# -eq 0 ] && [ -t 0 ]; then
  INTERACTIVE=true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hotfix)
      HOTFIX=true
      shift
      ;;
    --draft)
      DRAFT=true
      shift
      ;;
    --diff)
      DIFF=true
      # captura o branch se o próximo arg não for outra flag
      if [[ -n "$2" && "$2" != --* ]]; then
        DIFF_BRANCH="$2"
        shift 2
      else
        shift
      fi
      ;;
    --model)
      if [[ -n "$2" && "$2" != --* ]]; then
        GEMINI_MODEL="$2"
        shift 2
      else
        shift
      fi
      ;;
    --context)
      if [[ -n "$2" && "$2" != --* ]]; then
        EXTRA_CONTEXT="${EXTRA_CONTEXT}${EXTRA_CONTEXT:+$'\n'}$2"
        shift 2
      else
        shift
      fi
      ;;
    --context-file)
      if [[ -n "$2" && -f "$2" ]]; then
        EXTRA_CONTEXT="${EXTRA_CONTEXT}${EXTRA_CONTEXT:+$'\n'}$(cat "$2")"
        shift 2
      else
        echo "⚠️ Arquivo de contexto não encontrado: $2" >&2
        [[ -n "$2" ]] && shift 2 || shift
      fi
      ;;
    --list-models)
      LIST_MODELS=true
      shift
      ;;
    -i|--interactive)
      INTERACTIVE=true
      shift
      ;;
    --no-interactive)
      INTERACTIVE=false
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────
# --list-models: apenas lista os modelos disponíveis e sai
# ─────────────────────────────────────────────────────────────
if [ "$LIST_MODELS" = true ]; then
  if [ -z "$GEMINI_API_KEY_RESOLVED" ]; then
    echo "❌ Nenhuma API key encontrada (defina GEMINI_API_KEY ou crie $API_KEY_FILE)."
    exit 1
  fi
  echo "📋 Modelos disponíveis (suportam generateContent):"
  list_models "$GEMINI_API_KEY_RESOLVED" | sed 's/^/  - /'
  exit 0
fi

# ─────────────────────────────────────────────────────────────
# Modo interativo: pergunta as opções ao invés de exigir flags
# ─────────────────────────────────────────────────────────────
if [ "$INTERACTIVE" = true ]; then
  echo "🧭 Modo interativo (dica: use flags para pular as perguntas)"

  PS3=$'\n👉 Escolha o tipo de PR: '
  select _opt in "Normal (PR para release)" "Hotfix (PR para main/master)"; do
    case "$REPLY" in
      1) HOTFIX=false; break ;;
      2) HOTFIX=true; break ;;
      *) echo "❌ Opção inválida, tente novamente." ;;
    esac
  done

  read -rp $'\n📝 Criar como rascunho (draft)? [s/N]: ' _ans
  [[ "$_ans" =~ ^[Ss]$ ]] && DRAFT=true

  read -rp $'\n🔀 Comparar o diff com uma branch específica? (enter = base padrão): ' _ans
  if [ -n "$_ans" ]; then
    DIFF=true
    DIFF_BRANCH="$_ans"
  fi

  # Seleção dinâmica de modelo (apenas se houver API key)
  if [ -n "$GEMINI_API_KEY_RESOLVED" ]; then
    echo $'\n🔢 Buscando modelos disponíveis...'
    mapfile -t MODELS < <(list_models "$GEMINI_API_KEY_RESOLVED")
    if [ ${#MODELS[@]} -gt 0 ]; then
      PS3=$'\n👉 Escolha o modelo: '
      select _m in "Manter padrão ($GEMINI_MODEL)" "${MODELS[@]}" "Outro (digitar)"; do
        if [ -z "$_m" ]; then
          echo "❌ Opção inválida, tente novamente."
          continue
        fi
        case "$_m" in
          "Manter padrão "*) break ;;
          "Outro (digitar)") read -rp "Nome do modelo: " GEMINI_MODEL; break ;;
          *) GEMINI_MODEL="$_m"; break ;;
        esac
      done
    else
      echo "⚠️ Não foi possível listar modelos; mantendo '$GEMINI_MODEL'."
    fi
  fi

  # Contexto adicional (multilinha)
  read -rp $'\n💬 Adicionar contexto extra ao prompt? [s/N]: ' _ans
  if [[ "$_ans" =~ ^[Ss]$ ]]; then
    echo "   Digite o contexto e encerre com Ctrl-D em uma linha vazia:"
    EXTRA_CONTEXT=$(cat)
  fi

  echo ""
fi

echo "🔄 Buscando atualizações do repositório..."
git fetch origin

echo "🔎 Determinando a branch padrão..."

if git show-ref --verify --quiet refs/remotes/origin/main; then
  MAIN_BRANCH="main"
elif git show-ref --verify --quiet refs/remotes/origin/master; then
  MAIN_BRANCH="master"
else
  echo "❌ ERRO: Não foi possível encontrar 'origin/main' ou 'origin/master'."
  exit 1
fi

if [ "$DIFF" = true ]; then
  if [ -z "$DIFF_BRANCH" ]; then
    DIFF_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')
  fi
else
  DIFF_BRANCH="$MAIN_BRANCH"
fi

if [ "$HOTFIX" = true ]; then
  echo "🚨 Modo HOTFIX ativado — PR será criado para $MAIN_BRANCH"
  TARGET_BRANCH=$MAIN_BRANCH
else
  TARGET_BRANCH="release"
  echo "🚀 Modo normal — PR será criado para $TARGET_BRANCH"
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "🌿 Branch atual: $CURRENT_BRANCH"

echo "🔍 Gerando diff para $DIFF_BRANCH..."

GIT_DIFF=$(git diff "origin/$DIFF_BRANCH...HEAD" -- . \
  ':(exclude)*package-lock.json' \
  ':(exclude)*yarn.lock' \
  ':(exclude)dist/' \
  ':(exclude)build/' \
  ':(exclude)node_modules/' \
  ':(exclude)vendor/' \
  ':(exclude)*.min.js' \
  ':(exclude)*.min.css' \
  ':(exclude)*.map' \
  ':(exclude)*.png' \
  ':(exclude)*.jpg' \
  ':(exclude)*.jpeg' \
  ':(exclude)*.gif' \
  ':(exclude)*.svg' \
  ':(exclude)*.pdf' \
  ':(exclude)*.sqlite' \
  ':(exclude)*.db')

if [ -z "$GIT_DIFF" ]; then
  echo "⚠️ Nenhum diff relevante encontrado."
  exit 0
fi

# Template
if [ ! -f ".github/pull_request_template.md" ]; then
  echo "❌ Template não encontrado em .github/pull_request_template.md"
  exit 1
fi

TEMPLATE_PR=$(cat .github/pull_request_template.md)

# Extrai ID do ClickUp (ex: feat/868gfh2k9)
CLICKUP_ID=$(echo "$CURRENT_BRANCH" | grep -oE '(feat|fix|chore|docs|style|refactor|perf|test|build|ci|hotfix|wip|impr|lint)/([0-9a-z]{9})' | cut -d'/' -f2 || true)

if [ -n "$CLICKUP_ID" ]; then
  CLICKUP_LINK="[Link para a tarefa no ClickUp #$CLICKUP_ID](https://app.clickup.com/t/$CLICKUP_ID)"
  echo "🔗 ClickUp detectado: $CLICKUP_LINK"

  TEMPLATE_PR=$(echo "$TEMPLATE_PR" | sed "s|\[Link para a tarefa no ClickUp\]|$CLICKUP_LINK|g")
else
  echo "⚠️ Nenhum ID de ClickUp detectado na branch"
fi

# ─────────────────────────────────────────────────────────────
# 1º) Cria/garante o PR ANTES de gerar a descrição com IA.
#     O corpo inicial é o próprio template; a IA só atualiza depois.
# ─────────────────────────────────────────────────────────────
echo "⬆️ Garantindo que a branch está no remoto..."
git push -u --no-verify origin "$CURRENT_BRANCH" > /dev/null 2>&1

echo "🔎 Verificando se já existe PR..."

PR_TITLE="${CURRENT_BRANCH^}"
PR_NUMBER=$(gh pr list --head "$CURRENT_BRANCH" --json number --jq '.[0].number')

if [ -n "$PR_NUMBER" ]; then
  echo "✅ PR já existe (#$PR_NUMBER)."
else
  echo "🆕 Criando novo PR com o template (a descrição será preenchida em seguida)..."

  TEMPLATE_FILE=$(mktemp)
  printf '%s' "$TEMPLATE_PR" > "$TEMPLATE_FILE"

  CREATE_ARGS=(
    --base "$TARGET_BRANCH"
    --head "$CURRENT_BRANCH"
    --title "$PR_TITLE"
    --assignee @me
    --body-file "$TEMPLATE_FILE"
  )

  if [ "$DRAFT" = true ]; then
    CREATE_ARGS+=(--draft)
  fi

  gh pr create "${CREATE_ARGS[@]}"
  rm -f "$TEMPLATE_FILE"

  PR_NUMBER=$(gh pr list --head "$CURRENT_BRANCH" --json number --jq '.[0].number')
fi

# ─────────────────────────────────────────────────────────────
# 2º) Gera a descrição com IA (com cache, retentativas e tolerância a falha)
# ─────────────────────────────────────────────────────────────

# Tenta gerar via API REST (se houver key) ou via gemini CLI (fallback), com retentativas.
generate_pr_body() {
  local prompt="$1"
  local attempt=1
  local max_attempts=3
  local out

  while [ "$attempt" -le "$max_attempts" ]; do
    if [ -n "$GEMINI_API_KEY_RESOLVED" ]; then
      if out=$(generate_via_rest "$prompt" "$GEMINI_API_KEY_RESOLVED" "$GEMINI_MODEL") && [ -n "$out" ]; then
        printf '%s' "$out"
        return 0
      fi
    else
      if out=$(printf '%s' "$prompt" | node --max-old-space-size=8192 "$(which gemini)" -m "$GEMINI_MODEL" 2>/dev/null) \
        && [ -n "$out" ]; then
        printf '%s' "$out"
        return 0
      fi
    fi
    echo "⚠️ Tentativa $attempt/$max_attempts de gerar a descrição falhou..." >&2
    attempt=$((attempt + 1))
    [ "$attempt" -le "$max_attempts" ] && sleep 2
  done

  return 1
}

# Bloco de contexto adicional (só entra no prompt se houver conteúdo)
CONTEXT_BLOCK=""
if [ -n "$EXTRA_CONTEXT" ]; then
  CONTEXT_BLOCK="
---
CONTEXTO ADICIONAL DO AUTOR (informação autoritativa; use para complementar o diff):
$EXTRA_CONTEXT
"
fi

CACHE_DIR="$HOME/.cache/generate_pr"
mkdir -p "$CACHE_DIR"
CACHE_KEY=$(printf '%s\n%s\n%s\n%s' "$CURRENT_BRANCH" "$GEMINI_MODEL" "$EXTRA_CONTEXT" "$GIT_DIFF" | sha256sum | cut -d' ' -f1)
CACHE_FILE="$CACHE_DIR/$CACHE_KEY"

PR_BODY=""

if [ -f "$CACHE_FILE" ]; then
  echo "💾 Usando conteúdo do PR em cache (diff/contexto/modelo não mudaram)..."
  PR_BODY=$(cat "$CACHE_FILE")
else
  if [ -n "$GEMINI_API_KEY_RESOLVED" ]; then
    echo "🧠 Gerando conteúdo do PR via API REST (modelo: $GEMINI_MODEL)..."
  else
    echo "🧠 Gerando conteúdo do PR via gemini CLI (modelo: $GEMINI_MODEL)..."
  fi

  PROMPT=$(cat <<EOF
Você é um assistente de desenvolvimento sênior. Sua tarefa é preencher o template de Pull Request (PR) com base no git diff fornecido.

Regras obrigatórias:
1. Baseie-se no git diff fornecido. Quando houver "CONTEXTO ADICIONAL DO AUTOR", use-o como informação autoritativa complementar. Não invente informações além dessas fontes.
2. Retorne em formato Markdown contendo a ficha completa.
3. Não preencha a seção "## 📌 Checklist de Qualidade".
4. Mantenha todas as seções, subtópicos e checkboxes exatamente como estão, mesmo que vazios.
5. Não remova, renomeie ou reestruture títulos.
6. Sugira testes manuais apenas com base no diff e no contexto adicional.
7. Não adicione nenhum texto fora da ficha.

---
TEMPLATE:
$TEMPLATE_PR
$CONTEXT_BLOCK
---
DIFF:
$GIT_DIFF

---
RESULTADO:
EOF
)

  if PR_BODY=$(generate_pr_body "$PROMPT"); then
    printf '%s' "$PR_BODY" > "$CACHE_FILE"
  else
    echo "❌ Não foi possível gerar a descrição com a IA após várias tentativas."
    echo "ℹ️ O PR #$PR_NUMBER já foi criado com o template. Você pode rodar o script novamente mais tarde para preencher a descrição."
    PR_BODY=""
  fi
fi

# ─────────────────────────────────────────────────────────────
# 3º) Atualiza o corpo do PR com a descrição gerada (se houver)
# ─────────────────────────────────────────────────────────────
if [ -n "$PR_BODY" ]; then
  echo "✏️ Atualizando a descrição do PR #$PR_NUMBER..."

  TEMP_BODY_FILE=$(mktemp)
  printf '%s' "$PR_BODY" > "$TEMP_BODY_FILE"

  API_ARGS=(
    --method PATCH
    "repos/{owner}/{repo}/pulls/$PR_NUMBER"
    --field "body=@$TEMP_BODY_FILE"
  )

  gh api "${API_ARGS[@]}" > /dev/null
  rm -f "$TEMP_BODY_FILE"
fi

# Garante o assignee (caso o PR já existisse)
gh pr edit "$PR_NUMBER" --add-assignee @me > /dev/null 2>&1 || true

echo "✅ Processo finalizado!"
