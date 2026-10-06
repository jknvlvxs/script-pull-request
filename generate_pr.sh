#!/bin/bash

set -e

HOTFIX=false
DRAFT=false
EDIT_FLAG=false
DIFF=false
DIFF_BRANCH=""
INTERACTIVE=false
NO_INTERACTIVE=false
LIST_MODELS=false
EXTRA_CONTEXT=""
TARGET_OVERRIDE=""
MODEL_OVERRIDE=""

# Endpoint da Generative Language API (usada diretamente via curl quando há API key).
API_BASE="https://generativelanguage.googleapis.com/v1beta"

# Endpoint da Messages API da Anthropic (usada via curl quando há ANTHROPIC_API_KEY).
ANTHROPIC_API_BASE="https://api.anthropic.com/v1"

# ─────────────────────────────────────────────────────────────
# Dependências obrigatórias (falha cedo). Usa echo puro pois não
# podemos depender do gum para reportar a ausência do gum.
# Os CLIs gemini e claude são opcionais (usados só quando não há a
# respectiva API key).
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
# Fora de um terminal (CI, Claude Code) o gum spin só gera códigos ANSI na saída:
# nesse caso roda o comando direto e mostra a saída apenas se ele falhar.
ui_spin() {
  local title="$1"; shift
  if [ -t 2 ]; then
    gum spin --spinner dot --title "$title" -- "$@"
    return
  fi
  local out rc=0
  ui_log info "$title"
  out=$("$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] && printf '%s\n' "$out" >&2
  return "$rc"
}

# Spinner que captura a saída padrão do comando (para fetch de dados).
ui_spin_capture() {
  local title="$1"; shift
  if [ -t 2 ]; then
    gum spin --spinner dot --title "$title" --show-output -- "$@"
  else
    ui_log info "$title"
    "$@"
  fi
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

# Modelo padrão — definido só DEPOIS de carregar o .env, senão o default do código
# ocupa a variável e o GEMINI_MODEL do .env é ignorado.
# Precedência: flag --model / seleção interativa > env real > .env > default abaixo.
GEMINI_MODEL="${GEMINI_MODEL:-gemini-3.5-flash}"

# Provedor de IA (gemini | claude) e modelo Claude (sonnet | opus | haiku, ou um ID
# completo como claude-opus-5-5). Mesma precedência do GEMINI_MODEL.
AI_PROVIDER="${AI_PROVIDER:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"

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

# Claude: com ANTHROPIC_API_KEY (env ou .env) usa a Messages API; sem ela, usa o
# claude CLI (Claude Code) em modo não interativo, com a conta já logada.

# Traduz o apelido escolhido (sonnet/opus/haiku) para o ID do modelo na API.
# Qualquer outro valor é tratado como ID completo e repassado como está.
claude_api_model_id() {
  case "$1" in
    sonnet) printf '%s' "claude-sonnet-5" ;;
    opus)   printf '%s' "claude-opus-5-5" ;;
    haiku)  printf '%s' "claude-haiku-4-5" ;;
    *)      printf '%s' "$1" ;;
  esac
}

# Modelo em uso pelo provedor atual.
ai_model() {
  if [ "$AI_PROVIDER" = claude ]; then
    printf '%s' "$CLAUDE_MODEL"
  else
    printf '%s' "$GEMINI_MODEL"
  fi
}

# Rótulo legível para logs (ex.: "Claude · opus via claude CLI").
ai_model_label() {
  local via
  if [ "$AI_PROVIDER" = claude ]; then
    [ -n "$ANTHROPIC_API_KEY" ] && via="API da Anthropic" || via="claude CLI"
  else
    [ -n "$GEMINI_API_KEY_RESOLVED" ] && via="API REST" || via="gemini CLI"
  fi
  printf '%s · %s via %s' "${AI_PROVIDER^}" "$(ai_model)" "$via"
}

# O provedor tem como ser usado (API key ou CLI instalado)?
provider_available() {
  case "$1" in
    gemini) [ -n "$GEMINI_API_KEY_RESOLVED" ] || command -v gemini >/dev/null 2>&1 ;;
    claude) [ -n "$ANTHROPIC_API_KEY" ] || command -v claude >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

# Cache das descrições geradas e do contexto extra salvo.
CACHE_DIR="$HOME/.cache/generate_pr"

# Contexto extra salvo por repositório + branch, para não precisar redigitá-lo quando
# a geração falha. É gravado assim que o contexto é definido e apagado depois que a
# descrição é aplicada ao PR.
context_file() {
  local repo
  repo=$(basename "$(git rev-parse --show-toplevel)")
  printf '%s/context/%s/%s.md' "$CACHE_DIR" "$repo" "${CURRENT_BRANCH//\//__}"
}

save_context() {
  local file
  file=$(context_file)
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$EXTRA_CONTEXT" > "$file"
}

# Editor multilinha do contexto. Uso: edit_context [texto inicial]
edit_context() {
  gum write \
    --placeholder "Descreva o contexto (Ctrl+D para enviar)..." \
    --width 90 --height 8 \
    --value "${1:-}"
}

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

# Lista apenas os modelos Gemini *flash* de texto que suportam generateContent, do
# mais novo para o mais antigo. Fica de fora: pro, lite, image, tts, audio, etc.
# pageSize=1000: sem ele a API devolve só 50 modelos (paginado) e alguns sumiam.
list_models() {
  local key="$1"
  curl -s -m 20 -H "x-goog-api-key: $key" "$API_BASE/models?pageSize=1000" \
    | jq -r '.models[]? | select(.supportedGenerationMethods[]? == "generateContent") | .name' \
    | sed 's@models/@@' \
    | grep -E '^gemini-([0-9.]+-)?flash(-latest|-preview(-[0-9-]+)?)?$' \
    | sort -rV || true
}

# Gera conteúdo chamando a API REST do Gemini diretamente (evita o roteador interno do
# gemini CLI). O prompt e o payload são gravados em arquivos temporários para não estourar
# o ARG_MAX do shell com diffs grandes (jq --rawfile + curl -d @arquivo).
generate_via_gemini_api() {
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

# Gera conteúdo pela Messages API da Anthropic. Mesmo esquema de arquivos temporários
# do Gemini para suportar diffs grandes.
generate_via_claude_api() {
  local prompt="$1" key="$2" model="$3"
  local prompt_file payload_file resp text stop
  local -a beta_header=()
  local fallback=false

  prompt_file=$(mktemp)
  payload_file=$(mktemp)
  trap 'rm -f "$prompt_file" "$payload_file"' RETURN

  printf '%s' "$prompt" > "$prompt_file"

  # No Opus 5/5.5, se o classificador de segurança recusar o pedido (acontece com diffs
  # de código sensível), a própria API refaz a chamada em outro modelo.
  case "$model" in
    claude-opus-5|claude-opus-5-5)
      fallback=true
      beta_header=(-H "anthropic-beta: server-side-fallback-2026-07-01")
      ;;
  esac

  if ! jq -n --rawfile t "$prompt_file" --arg m "$model" --argjson fb "$fallback" \
    '{model:$m, max_tokens:16000, messages:[{role:"user", content:$t}]}
     + (if $fb then {fallbacks:"default"} else {} end)' > "$payload_file"; then
    ui_log error "Falha ao montar o payload JSON."
    return 1
  fi

  resp=$(curl -s -m 300 \
    -H "content-type: application/json" \
    -H "x-api-key: $key" \
    -H "anthropic-version: 2023-06-01" \
    "${beta_header[@]}" \
    -X POST --data-binary "@$payload_file" \
    "$ANTHROPIC_API_BASE/messages")

  if printf '%s' "$resp" | jq -e '.type == "error"' >/dev/null 2>&1; then
    ui_log error "API Claude: $(printf '%s' "$resp" | jq -r '.error.message // "erro desconhecido"')"
    return 1
  fi

  stop=$(printf '%s' "$resp" | jq -r '.stop_reason // empty')
  if [ "$stop" = "refusal" ]; then
    ui_log error "O Claude recusou gerar a descrição (stop_reason=refusal)."
    return 1
  fi

  # Com adaptive thinking a resposta pode trazer blocos "thinking"; só o texto importa.
  text=$(printf '%s' "$resp" | jq -r '[.content[]? | select(.type == "text") | .text] | join("")')

  if [ -z "$text" ] || [ "$text" = "null" ]; then
    return 1
  fi

  [ "$stop" = "max_tokens" ] && ui_log warn "A resposta atingiu o limite de tokens e pode estar incompleta."

  printf '%s' "$text"
}

# Gera conteúdo pelo claude CLI (Claude Code) em modo não interativo, usando a conta já
# logada. Sem ferramentas e com system prompt próprio: o modelo só devolve o texto.
generate_via_claude_cli() {
  local prompt="$1" model="$2" out rc=0

  out=$(printf '%s' "$prompt" | claude -p \
    --model "$model" \
    --tools "" \
    --no-session-persistence \
    --output-format text \
    --system-prompt "Você preenche templates de Pull Request a partir de um git diff. Responda somente com o Markdown pedido, sem comentários antes ou depois." \
    2>/dev/null) || rc=$?

  if [ "$rc" -ne 0 ]; then
    # Em caso de erro o claude CLI escreve o motivo no stdout.
    ui_log error "claude CLI: $(printf '%s' "$out" | head -n1)"
    return 1
  fi

  printf '%s' "$out"
}

# Seleção interativa do modelo Gemini (apenas flash). Sem API key não há como listar,
# então mantém o GEMINI_MODEL configurado.
choose_gemini_model() {
  local models_raw keep_opt model

  if [ -z "$GEMINI_API_KEY_RESOLVED" ]; then
    ui_log warn "Sem GEMINI_API_KEY não é possível listar modelos; mantendo '$GEMINI_MODEL'."
    return 0
  fi

  export API_BASE
  export -f list_models
  models_raw=$(ui_spin_capture "Buscando modelos Gemini flash disponíveis..." \
    bash -c 'list_models "$0"' "$GEMINI_API_KEY_RESOLVED")
  if [ -z "$models_raw" ]; then
    ui_log warn "Não foi possível listar modelos; mantendo '$GEMINI_MODEL'."
    return 0
  fi

  keep_opt="» Manter modelo atual ($GEMINI_MODEL)"
  if ! model=$( { printf '%s\n' "$keep_opt"; printf '%s\n' "$models_raw"; } \
    | gum filter --placeholder "Filtrar o modelo Gemini..." --height 15); then
    _abort_cancel
  fi
  if [ "$model" != "$keep_opt" ] && [ -n "$model" ]; then
    GEMINI_MODEL="$model"
  fi
}

# Seleção interativa do modelo Claude (Sonnet, Opus ou Haiku).
choose_claude_model() {
  local sonnet="Sonnet — equilíbrio entre qualidade e velocidade"
  local opus="Opus — mais capaz, mais lento"
  local haiku="Haiku — mais rápido e econômico"
  local -a opts=()
  local keep_opt="" selected choice

  # Um ID completo vindo do .env/--model continua disponível como primeira opção.
  case "$CLAUDE_MODEL" in
    sonnet) selected="$sonnet" ;;
    opus)   selected="$opus" ;;
    haiku)  selected="$haiku" ;;
    *)      keep_opt="» Manter modelo atual ($CLAUDE_MODEL)"; selected="$keep_opt"; opts+=("$keep_opt") ;;
  esac
  opts+=("$sonnet" "$opus" "$haiku")

  if ! choice=$(gum choose "${opts[@]}" --header "Modelo Claude" --selected "$selected"); then
    _abort_cancel
  fi
  case "$choice" in
    Sonnet*) CLAUDE_MODEL=sonnet ;;
    Opus*)   CLAUDE_MODEL=opus ;;
    Haiku*)  CLAUDE_MODEL=haiku ;;
  esac
}

# Seleção interativa de provedor + modelo. Só oferece os provedores utilizáveis;
# com apenas um disponível, pula direto para a escolha do modelo.
choose_model() {
  local -a providers=()
  local provider

  provider_available gemini && providers+=("Gemini")
  provider_available claude && providers+=("Claude")

  if [ ${#providers[@]} -eq 0 ]; then
    ui_log error "Nenhum provedor de IA disponível (configure GEMINI_API_KEY/ANTHROPIC_API_KEY ou instale o gemini/claude CLI)."
    exit 1
  elif [ ${#providers[@]} -eq 1 ]; then
    provider="${providers[0]}"
  elif ! provider=$(gum choose "${providers[@]}" --header "Provedor de IA" \
    --selected "${AI_PROVIDER^}"); then
    _abort_cancel
  fi

  case "$provider" in
    Claude) AI_PROVIDER=claude; choose_claude_model ;;
    *)      AI_PROVIDER=gemini; choose_gemini_model ;;
  esac
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
    --edit)
      EDIT_FLAG=true
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
        MODEL_OVERRIDE="$2"
        shift 2
      else
        shift
      fi
      ;;
    --provider)
      if [[ -n "$2" && "$2" != --* ]]; then
        AI_PROVIDER="$2"
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
      NO_INTERACTIVE=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# --model define o provedor quando o nome é reconhecível (gemini-* → Gemini;
# sonnet/opus/haiku/claude-* → Claude). Outros nomes valem para o provedor atual.
if [ -n "$MODEL_OVERRIDE" ]; then
  case "$MODEL_OVERRIDE" in
    gemini-*)                   AI_PROVIDER=gemini ;;
    sonnet|opus|haiku|claude-*) AI_PROVIDER=claude ;;
  esac
  if [ "$AI_PROVIDER" = claude ]; then
    CLAUDE_MODEL="$MODEL_OVERRIDE"
  else
    GEMINI_MODEL="$MODEL_OVERRIDE"
  fi
fi

case "$AI_PROVIDER" in
  gemini|claude) ;;
  *)
    ui_log error "Provedor de IA inválido: '$AI_PROVIDER' (use gemini ou claude)."
    exit 1
    ;;
esac

# ─────────────────────────────────────────────────────────────
# --list-models: apenas lista os modelos disponíveis e sai
# ─────────────────────────────────────────────────────────────
if [ "$LIST_MODELS" = true ]; then
  if [ -n "$GEMINI_API_KEY_RESOLVED" ]; then
    echo "📋 Modelos Gemini flash disponíveis:"
    list_models "$GEMINI_API_KEY_RESOLVED" | sed 's/^/  - /'
  else
    ui_log warn "Sem GEMINI_API_KEY (ou $API_KEY_FILE) não é possível listar os modelos Gemini."
  fi
  echo "📋 Modelos Claude (use o apelido em --model):"
  for _alias in sonnet opus haiku; do
    echo "  - $_alias ($(claude_api_model_id "$_alias"))"
  done
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

# --edit: atualiza a descrição do PR aberto desta branch, qualquer que seja o destino
# (ignora --hotfix/--base).
if [ "$EDIT_FLAG" = true ]; then
  if [ -z "$EXISTING_PR_NUMBER" ]; then
    ui_log error "--edit: não há PR aberto da branch $CURRENT_BRANCH para editar."
    exit 1
  fi
  EDIT_EXISTING=true
fi

# ─────────────────────────────────────────────────────────────
# Modo interativo: escolhas navegáveis por teclado (gum)
# ─────────────────────────────────────────────────────────────
if [ "$INTERACTIVE" = true ]; then
  # 0) Se já existe PR: editar (nova descrição) ou criar um novo (outro destino)?
  #    Pulado quando --edit já decidiu.
  if [ -n "$EXISTING_PR_NUMBER" ] && [ "$EDIT_EXISTING" != true ]; then
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

  # 4) Provedor (Gemini/Claude) e modelo
  choose_model

  # 5) Contexto adicional (gum write multilinha). Se sobrou um contexto salvo de uma
  #    execução que falhou, oferece reaproveitá-lo em vez de redigitar.
  _saved_file=$(context_file)
  if [ -s "$_saved_file" ]; then
    _saved=$(cat "$_saved_file")
    _preview=$(printf '%s\n' "$_saved" | head -n 12)
    [ "$(printf '%s\n' "$_saved" | wc -l)" -gt 12 ] && _preview="$_preview"$'\n…'
    gum style --border rounded --padding "0 1" --border-foreground 240 "$_preview"
    if ! _ctx_action=$(gum choose \
      "Usar o contexto salvo" \
      "Editar o contexto salvo" \
      "Escrever um novo contexto" \
      "Descartar o contexto salvo e seguir sem contexto" \
      --header "Há um contexto extra salvo de uma execução anterior"); then
      _abort_cancel
    fi
    case "$_ctx_action" in
      Usar*)     EXTRA_CONTEXT="$_saved" ;;
      Editar*)   EXTRA_CONTEXT=$(edit_context "$_saved") || _abort_cancel ;;
      Escrever*) EXTRA_CONTEXT=$(edit_context) || _abort_cancel ;;
      *)         EXTRA_CONTEXT=""; rm -f "$_saved_file" ;;
    esac
  elif ui_confirm "Adicionar contexto extra ao prompt?" --default=false; then
    EXTRA_CONTEXT=$(edit_context) || _abort_cancel
  fi
fi

# Salva o contexto já aqui: se algo falhar daqui em diante (push, IA, Ctrl+C), a
# próxima execução interativa o oferece de volta.
[ -n "$EXTRA_CONTEXT" ] && save_context

# Falha antes de criar/alterar o PR se o provedor escolhido não tiver como rodar.
if ! provider_available "$AI_PROVIDER"; then
  if [ "$AI_PROVIDER" = claude ]; then
    ui_log error "Claude indisponível: defina ANTHROPIC_API_KEY ou instale o claude CLI (Claude Code)."
  else
    ui_log error "Gemini indisponível: defina GEMINI_API_KEY ou instale o gemini CLI."
  fi
  exit 1
fi
ui_log info "🤖 Modelo: $(ai_model_label)"

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

# Destino igual ao de um PR já aberto (o GitHub só permite um PR aberto por par
# origem→destino). No modo interativo o usuário escolheu "Criar um novo PR", então é
# erro; sem modo interativo o PR existente é reutilizado e só a descrição é refeita.
if [ "$EDIT_EXISTING" != true ] && [ -n "$EXISTING_PR_NUMBER" ] \
   && [ "$EXISTING_PR_BASE" = "$TARGET_BRANCH" ]; then
  if [ "$INTERACTIVE" = true ]; then
    ui_log error "Já existe PR #$EXISTING_PR_NUMBER de $CURRENT_BRANCH → $TARGET_BRANCH."
    ui_log info "Escolha outro destino para o novo PR ou edite o existente."
    exit 1
  fi
  EDIT_EXISTING=true
  ui_log info "♻️ Reutilizando o PR existente #$EXISTING_PR_NUMBER — a descrição será atualizada."
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

# Uma tentativa de geração com o provedor/modelo atual. Cada provedor usa a API
# quando há key e o CLI correspondente como fallback. Imprime o texto no stdout.
generate_once() {
  local prompt="$1"

  if [ "$AI_PROVIDER" = claude ]; then
    if [ -n "$ANTHROPIC_API_KEY" ]; then
      generate_via_claude_api "$prompt" "$ANTHROPIC_API_KEY" "$(claude_api_model_id "$CLAUDE_MODEL")"
    else
      generate_via_claude_cli "$prompt" "$CLAUDE_MODEL"
    fi
  elif [ -n "$GEMINI_API_KEY_RESOLVED" ]; then
    generate_via_gemini_api "$prompt" "$GEMINI_API_KEY_RESOLVED" "$GEMINI_MODEL"
  else
    printf '%s' "$prompt" | node --max-old-space-size=8192 "$(which gemini)" -m "$GEMINI_MODEL" 2>/dev/null
  fi
}

# Falhas seguidas no mesmo modelo antes de oferecer a troca.
MAX_ATTEMPTS_PER_MODEL=2

# Dá para abrir prompts? Exige terminal e respeita --no-interactive (CI/automação).
# Vale também quando o script foi chamado com flags num terminal.
can_prompt() {
  [ -t 0 ] && [ "$NO_INTERACTIVE" != true ]
}

# Gera a descrição e a guarda em PR_BODY (sem subshell, para que uma troca de modelo
# feita aqui valha para o resto do script). Após MAX_ATTEMPTS_PER_MODEL falhas seguidas
# no mesmo modelo, pergunta se quer trocar de modelo, tentar de novo ou desistir; sem
# terminal, desiste direto.
generate_pr_body() {
  local prompt="$1"
  local attempt=1
  local out action

  while true; do
    [ "$attempt" -eq 1 ] && ui_log info "🧠 Gerando conteúdo do PR ($(ai_model_label))..."

    if out=$(generate_once "$prompt") && [ -n "$out" ]; then
      PR_BODY="$out"
      return 0
    fi

    ui_log warn "Tentativa $attempt/$MAX_ATTEMPTS_PER_MODEL com $(ai_model) falhou."
    if [ "$attempt" -lt "$MAX_ATTEMPTS_PER_MODEL" ]; then
      attempt=$((attempt + 1))
      sleep 2
      continue
    fi

    can_prompt || return 1

    # Esc aqui equivale a desistir: o PR já existe com o template.
    action=$(gum choose \
      "Trocar de modelo" \
      "Tentar de novo com $(ai_model)" \
      "Desistir (o PR fica com o template)" \
      --header "$MAX_ATTEMPTS_PER_MODEL falhas seguidas com $(ai_model_label)") || return 1

    case "$action" in
      Trocar*) choose_model ;;
      Tentar*) ;;
      *)       return 1 ;;
    esac
    attempt=1
  done
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

mkdir -p "$CACHE_DIR"
# Arquivo de cache para o provedor/modelo atual (recalculado se o modelo for trocado).
cache_file() {
  printf '%s/%s' "$CACHE_DIR" \
    "$(printf '%s\n%s\n%s\n%s' "$CURRENT_BRANCH" "$AI_PROVIDER:$(ai_model)" "$EXTRA_CONTEXT" "$GIT_DIFF" \
      | sha256sum | cut -d' ' -f1)"
}
CACHE_FILE=$(cache_file)

PR_BODY=""

if [ -f "$CACHE_FILE" ]; then
  ui_log info "💾 Usando conteúdo do PR em cache (diff/contexto/modelo não mudaram)..."
  PR_BODY=$(cat "$CACHE_FILE")
else
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

  if generate_pr_body "$PROMPT"; then
    # O modelo pode ter sido trocado durante a geração: salva na chave do modelo final.
    printf '%s' "$PR_BODY" > "$(cache_file)"
  else
    ui_log error "Não foi possível gerar a descrição com a IA."
    ui_log info "O PR #$PR_NUMBER já foi criado com o template. Rode o script novamente mais tarde para preencher a descrição."
    if [ -n "$EXTRA_CONTEXT" ]; then
      ui_log info "💾 Contexto extra salvo em $(context_file) — será oferecido na próxima execução interativa."
    fi
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

  # A descrição foi aplicada: o contexto salvo já cumpriu seu papel.
  [ -n "$EXTRA_CONTEXT" ] && rm -f "$(context_file)"
fi

# Garante o assignee (caso o PR já existisse)
gh pr edit "$PR_NUMBER" --add-assignee @me > /dev/null 2>&1 || true

ui_success "PR #$PR_NUMBER pronto!"
