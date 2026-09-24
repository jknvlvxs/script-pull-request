#!/bin/bash

set -e

HOTFIX=false
DRAFT=false
DIFF=false
DIFF_BRANCH=""
INTERACTIVE=false
LIST_MODELS=false
EXTRA_CONTEXT=""
TARGET_OVERRIDE=""

# Endpoint da Generative Language API (usada diretamente via curl quando há API key).
API_BASE="https://generativelanguage.googleapis.com/v1beta"

# Modelo padrão. Pode ser sobrescrito via env GEMINI_MODEL, flag --model ou seleção interativa.
GEMINI_MODEL="${GEMINI_MODEL:-gemini-3.5-flash}"

# ─────────────────────────────────────────────────────────────
# Dependências obrigatórias (falha cedo). Usa echo puro pois não
# podemos depender do gum para reportar a ausência do gum.
# O gemini CLI é opcional (fallback apenas quando não há API key).
# ─────────────────────────────────────────────────────────────
_missing_dep=
for _dep in gum gh jq curl git; do
  command -v "$_dep" >/dev/null 2>&1 || { echo "❌ Dependência ausente: $_dep"; _missing_dep=1; }
done
if [ -n "$_missing_dep" ]; then
  echo "ℹ️  Instale as dependências acima e tente novamente (veja o README.md)."
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# Camada de UI (gum)
# ─────────────────────────────────────────────────────────────

# Cabeçalho/banner.
ui_header() {
  gum style --border rounded --margin "1 0" --padding "0 2" \
    --border-foreground 212 --foreground 212 --bold "$1"
}

# Log consistente. Uso: ui_log <info|warn|error|debug> "mensagem"
ui_log() {
  local level="$1"; shift
  gum log --level "$level" -- "$*"
}

# Caixa de sucesso destacada.
ui_success() {
  gum style --border rounded --padding "0 2" --margin "1 0" \
    --border-foreground 42 --foreground 42 --bold "$1"
}

# Spinner para comandos demorados (sem capturar saída). Propaga o exit code.
ui_spin() {
  local title="$1"; shift
  gum spin --spinner dot --title "$title" -- "$@"
}

# Spinner que captura a saída padrão do comando (para fetch de dados).
ui_spin_capture() {
  local title="$1"; shift
  gum spin --spinner dot --title "$title" --show-output -- "$@"
}

# Encerra o script quando o usuário cancela um prompt do gum (Ctrl+C / Esc).
# Deve ser chamado fora de uma substituição $(...) para que o exit atinja o script.
_abort_cancel() {
  ui_log warn "Operação cancelada pelo usuário."
  exit 130
}

# gum confirm com 3 estados: 0 = sim, 1 = não, abort (Ctrl+C/Esc) = encerra o script.
ui_confirm() {
  local rc=0
  gum confirm "$@" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) _abort_cancel ;;
  esac
}

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

# Lista as branches remotas (sem o HEAD), uma por linha.
remote_branches() {
  git branch -r --format='%(refname:short)' \
    | sed 's@^origin/@@' | grep -vx 'HEAD' | sort -u
}

# Verifica se uma branch existe no remoto (após o fetch).
remote_branch_exists() {
  git show-ref --verify --quiet "refs/remotes/origin/$1"
}

# Template de PR padrão, usado quando não há .github/pull_request_template.md.
# Mantém o placeholder do ClickUp e a seção de checklist (que a IA não preenche).
DEFAULT_TEMPLATE='## 📋 Descrição

<!-- Descreva o que este PR faz e por quê. -->

## 🔄 Tipo de mudança

- [ ] 🐛 Correção de bug
- [ ] ✨ Nova funcionalidade
- [ ] ♻️ Refatoração
- [ ] 📝 Documentação

## 🧪 Como testar

<!-- Passos para validar manualmente as mudanças. -->'

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
# O prompt e o payload são gravados em arquivos temporários para não estourar o ARG_MAX
# do shell com diffs grandes (jq --rawfile + curl -d @arquivo).
generate_via_rest() {
  local prompt="$1" key="$2" model="$3"
  local prompt_file payload_file resp text rc

  prompt_file=$(mktemp)
  payload_file=$(mktemp)
  # Garante limpeza dos temporários ao sair da função.
  trap 'rm -f "$prompt_file" "$payload_file"' RETURN

  printf '%s' "$prompt" > "$prompt_file"

  # Monta o JSON lendo o prompt do arquivo (não passa pela linha de comando).
  if ! jq -n --rawfile t "$prompt_file" \
    '{contents:[{parts:[{text:$t}]}]}' > "$payload_file"; then
    ui_log error "Falha ao montar o payload JSON."
    return 1
  fi

  # Envia o corpo a partir do arquivo (evita limites de argv).
  resp=$(curl -s -m 180 \
    -H "Content-Type: application/json" \
    -H "x-goog-api-key: $key" \
    -X POST --data-binary "@$payload_file" \
    "$API_BASE/models/$model:generateContent")

  if printf '%s' "$resp" | jq -e '.error' >/dev/null 2>&1; then
    ui_log error "API: $(printf '%s' "$resp" | jq -r '.error.message // "erro desconhecido"')"
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
    --base|--target)
      if [[ -n "$2" && "$2" != --* ]]; then
        TARGET_OVERRIDE="$2"
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
        ui_log warn "Arquivo de contexto não encontrado: $2"
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
    ui_log error "Nenhuma API key encontrada (defina GEMINI_API_KEY ou crie $API_KEY_FILE)."
    exit 1
  fi
  echo "📋 Modelos disponíveis (suportam generateContent):"
  list_models "$GEMINI_API_KEY_RESOLVED" | sed 's/^/  - /'
  exit 0
fi

# ─────────────────────────────────────────────────────────────
# Atualiza o repositório (necessário em ambos os modos) — antes de
# perguntar para que a lista de branches/modelos esteja disponível.
# ─────────────────────────────────────────────────────────────
ui_header "Gerador de Pull Request"

ui_spin "Buscando atualizações do repositório..." git fetch origin

if git show-ref --verify --quiet refs/remotes/origin/main; then
  MAIN_BRANCH="main"
elif git show-ref --verify --quiet refs/remotes/origin/master; then
  MAIN_BRANCH="master"
else
  ui_log error "Não foi possível encontrar 'origin/main' ou 'origin/master'."
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# ─────────────────────────────────────────────────────────────
# Detecta cedo se já existe um PR aberto desta branch (número + base).
# Apenas consulta o GitHub (após o fetch) — não precisa de push aqui.
# ─────────────────────────────────────────────────────────────
EDIT_EXISTING=false
EXISTING_PR_JSON=$(gh pr list --head "$CURRENT_BRANCH" --state open \
  --json number,baseRefName --jq '.[0] // empty')
EXISTING_PR_NUMBER=$(printf '%s' "$EXISTING_PR_JSON" | jq -r '.number // empty')
EXISTING_PR_BASE=$(printf '%s' "$EXISTING_PR_JSON" | jq -r '.baseRefName // empty')
if [ -n "$EXISTING_PR_NUMBER" ]; then
  ui_log info "🔎 Já existe PR #$EXISTING_PR_NUMBER ($CURRENT_BRANCH → $EXISTING_PR_BASE)."
fi

# ─────────────────────────────────────────────────────────────
# Modo interativo: escolhas navegáveis por teclado (gum)
# ─────────────────────────────────────────────────────────────
if [ "$INTERACTIVE" = true ]; then
  # 0) Se já existe PR: editar (nova descrição) ou criar um novo (outro destino)?
  if [ -n "$EXISTING_PR_NUMBER" ]; then
    if ! _acao=$(gum choose \
      "Editar o PR existente (#$EXISTING_PR_NUMBER → $EXISTING_PR_BASE) — gerar nova descrição" \
      "Criar um novo PR (outra branch de destino)" \
      --header "PR já existe para esta branch"); then
      _abort_cancel
    fi
    case "$_acao" in
      Editar*) EDIT_EXISTING=true ;;
    esac
  fi

  # 1) Tipo de PR (gum choose — navegação por setas) — pulado ao editar PR existente
  if [ "$EDIT_EXISTING" != true ]; then
  if ! _tipo=$(gum choose \
    "Normal — PR para release" \
    "Hotfix — PR para main/master" \
    "Outra — escolher branch de destino" \
    --header "Tipo de PR" \
    --selected "Normal — PR para release"); then
    _abort_cancel
  fi
  case "$_tipo" in
    Hotfix*) HOTFIX=true ;;
    Outra*)
      if ! _target=$(remote_branches \
        | gum filter --placeholder "Escolha a branch de destino do PR..." --height 15); then
        _abort_cancel
      fi
      TARGET_OVERRIDE="$_target"
      ;;
    *)       HOTFIX=false ;;
  esac

  # 2) Draft? (gum confirm — Sim/Não)
  if ui_confirm "Criar como rascunho (draft)?" --default=false; then
    DRAFT=true
  fi
  fi  # fim do bloco "não está editando PR existente"

  # 3) Branch de comparação (gum filter — busca incremental)
  _DEFAULT_OPT="» Usar base padrão ($MAIN_BRANCH)"
  _branches=$( { printf '%s\n' "$_DEFAULT_OPT"; remote_branches; } )
  if ! _chosen=$(printf '%s\n' "$_branches" \
    | gum filter --placeholder "Filtrar branch de comparação..." --height 15); then
    _abort_cancel
  fi
  if [ "$_chosen" != "$_DEFAULT_OPT" ]; then
    DIFF=true
    DIFF_BRANCH="$_chosen"
  fi

  # 4) Modelo Gemini (gum filter — busca incremental, padrão pré-selecionado)
  if [ -n "$GEMINI_API_KEY_RESOLVED" ]; then
    export API_BASE
    export -f list_models
    MODELS_RAW=$(ui_spin_capture "Buscando modelos Gemini disponíveis..." \
      bash -c 'list_models "$0"' "$GEMINI_API_KEY_RESOLVED")
    if [ -n "$MODELS_RAW" ]; then
      _KEEP_OPT="» Manter modelo atual ($GEMINI_MODEL)"
      _models_list=$( { printf '%s\n' "$_KEEP_OPT"; printf '%s\n' "$MODELS_RAW"; } )
      if ! _model=$(printf '%s\n' "$_models_list" \
        | gum filter --placeholder "Filtrar o modelo Gemini..." --height 15); then
        _abort_cancel
      fi
      if [ "$_model" != "$_KEEP_OPT" ] && [ -n "$_model" ]; then
        GEMINI_MODEL="$_model"
      fi
    else
      ui_log warn "Não foi possível listar modelos; mantendo '$GEMINI_MODEL'."
    fi
  fi

  # 5) Contexto adicional (gum confirm + gum write multilinha)
  if ui_confirm "Adicionar contexto extra ao prompt?" --default=false; then
    if ! EXTRA_CONTEXT=$(gum write \
      --placeholder "Descreva o contexto (Ctrl+D para enviar)..." \
      --width 90 --height 8); then
      _abort_cancel
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────
# Resolve branch de comparação e branch alvo
# ─────────────────────────────────────────────────────────────
if [ "$DIFF" = true ]; then
  if [ -z "$DIFF_BRANCH" ]; then
    DIFF_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')
  fi
else
  DIFF_BRANCH="$MAIN_BRANCH"
fi

if [ "$EDIT_EXISTING" = true ]; then
  TARGET_BRANCH="$EXISTING_PR_BASE"
  ui_log info "✏️ Editando PR existente #$EXISTING_PR_NUMBER (destino $TARGET_BRANCH)"
elif [ -n "$TARGET_OVERRIDE" ]; then
  TARGET_BRANCH="$TARGET_OVERRIDE"
  ui_log info "🎯 PR será criado para $TARGET_BRANCH (definido manualmente)"
elif [ "$HOTFIX" = true ]; then
  TARGET_BRANCH=$MAIN_BRANCH
  ui_log info "🚨 Modo HOTFIX — PR será criado para $MAIN_BRANCH"
else
  TARGET_BRANCH="release"
  ui_log info "🚀 Modo normal — PR será criado para $TARGET_BRANCH"
fi

# Ao criar um novo PR, bloqueia se o destino colidir com um PR já existente
# (o GitHub só permite um PR aberto por par origem→destino).
if [ "$EDIT_EXISTING" != true ] && [ -n "$EXISTING_PR_NUMBER" ] \
   && [ "$EXISTING_PR_BASE" = "$TARGET_BRANCH" ]; then
  ui_log error "Já existe PR #$EXISTING_PR_NUMBER de $CURRENT_BRANCH → $TARGET_BRANCH."
  ui_log info "Escolha outro destino para o novo PR ou edite o existente."
  exit 1
fi

# Garante que a branch de destino existe no remoto.
if ! remote_branch_exists "$TARGET_BRANCH"; then
  ui_log error "A branch de destino 'origin/$TARGET_BRANCH' não existe no remoto."
  ui_log info "Branches disponíveis: $(remote_branches | paste -sd', ')"
  exit 1
fi

ui_log info "🌿 Branch atual: $CURRENT_BRANCH"

ui_log info "🔍 Gerando diff para $DIFF_BRANCH..."

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
  ui_log warn "Nenhum diff relevante encontrado."
  exit 0
fi

# Template (usa o do repositório; se não existir, cai no template padrão embutido)
if [ -f ".github/pull_request_template.md" ]; then
  TEMPLATE_PR=$(cat .github/pull_request_template.md)
else
  ui_log warn "Template .github/pull_request_template.md não encontrado — usando template padrão."
  TEMPLATE_PR="$DEFAULT_TEMPLATE"
fi

# Extrai ID do ClickUp (ex: feat/868gfh2k9)
CLICKUP_ID=$(echo "$CURRENT_BRANCH" | grep -oE '(feat|fix|chore|docs|style|refactor|perf|test|build|ci|hotfix|wip|impr|lint)/([0-9a-z]{9})' | cut -d'/' -f2 || true)

if [ -n "$CLICKUP_ID" ]; then
  CLICKUP_LINK="[Link para a tarefa no ClickUp #$CLICKUP_ID](https://app.clickup.com/t/$CLICKUP_ID)"
  ui_log info "🔗 ClickUp detectado: #$CLICKUP_ID"

  TEMPLATE_PR=$(echo "$TEMPLATE_PR" | sed "s|\[Link para a tarefa no ClickUp\]|$CLICKUP_LINK|g")
else
  ui_log warn "Nenhum ID de ClickUp detectado na branch"
fi

# ─────────────────────────────────────────────────────────────
# 1º) Cria/garante o PR ANTES de gerar a descrição com IA.
#     O corpo inicial é o próprio template; a IA só atualiza depois.
# ─────────────────────────────────────────────────────────────
ui_spin "Garantindo que a branch está no remoto..." \
  git push -u --no-verify origin "$CURRENT_BRANCH"

ui_log info "🔎 Verificando se já existe PR..."

PR_TITLE="${CURRENT_BRANCH^}"
PR_NUMBER=$(gh pr list --head "$CURRENT_BRANCH" --base "$TARGET_BRANCH" --state open --json number --jq '.[0].number')

if [ -n "$PR_NUMBER" ]; then
  ui_log info "✅ PR já existe (#$PR_NUMBER)."
else
  ui_log info "🆕 Criando novo PR com o template (a descrição será preenchida em seguida)..."

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

  PR_NUMBER=$(gh pr list --head "$CURRENT_BRANCH" --base "$TARGET_BRANCH" --state open --json number --jq '.[0].number')
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
    ui_log warn "Tentativa $attempt/$max_attempts de gerar a descrição falhou..."
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
  ui_log info "💾 Usando conteúdo do PR em cache (diff/contexto/modelo não mudaram)..."
  PR_BODY=$(cat "$CACHE_FILE")
else
  if [ -n "$GEMINI_API_KEY_RESOLVED" ]; then
    ui_log info "🧠 Gerando conteúdo do PR via API REST (modelo: $GEMINI_MODEL)..."
  else
    ui_log info "🧠 Gerando conteúdo do PR via gemini CLI (modelo: $GEMINI_MODEL)..."
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
    ui_log error "Não foi possível gerar a descrição com a IA após várias tentativas."
    ui_log info "O PR #$PR_NUMBER já foi criado com o template. Rode o script novamente mais tarde para preencher a descrição."
    PR_BODY=""
  fi
fi

# ─────────────────────────────────────────────────────────────
# 3º) Atualiza o corpo do PR com a descrição gerada (se houver)
# ─────────────────────────────────────────────────────────────
if [ -n "$PR_BODY" ]; then
  ui_log info "✏️ Atualizando a descrição do PR #$PR_NUMBER..."

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

ui_success "PR #$PR_NUMBER pronto!"
