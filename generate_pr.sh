#!/usr/bin/env bash

set -e

HOTFIX=false
DRAFT=false
VERIFY_HOOKS=false
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

# Ajuda do comando. Texto puro: precisa funcionar antes da checagem de dependências.
usage() {
  local cmd
  cmd="${0##*/}"
  cat <<EOF
Uso: $cmd [opções]

Cria (ou atualiza) o Pull Request da branch atual e preenche a descrição com
IA a partir do diff. Sem opções, num terminal, abre o modo interativo.

Destino do PR:
  --hotfix                    PR para main/master (padrão: release)
  --base, --target <branch>   define a branch de destino
  --edit                      só atualiza a descrição do PR aberto da branch
  --draft                     cria o PR como rascunho

Descrição:
  --model <nome>              opus | sonnet | haiku | claude-* | gemini-*
                              (padrão: opus, ou o que estiver no .env)
  --provider <nome>           claude | gemini (normalmente deduzido do --model)
  --context "<texto>"         contexto extra para o prompt (pode repetir)
  --context-file <arquivo>    contexto extra lido de um arquivo
  --diff [branch]             gera o diff contra outra branch (padrão:
                              main/master; sem valor, a branch padrão do remoto)

Execução:
  -i, --interactive           força o modo interativo
  --no-interactive            não pergunta nada e aplica a descrição direto (CI)
  --verify                    roda os hooks de pre-push (pulados por padrão)
  --list-models               lista os modelos disponíveis e sai
  -h, --help                  mostra esta ajuda

Exemplos:
  $cmd                                modo interativo
  $cmd --hotfix --draft               hotfix como rascunho
  $cmd --edit --model sonnet          refaz a descrição do PR aberto
  $cmd --context "Corrige o timeout"  acrescenta contexto ao prompt

Configuração em ~/.config/generate_pr/.env (provedor, modelo e API keys).
Documentação completa no README.md do repositório.
EOF
}

for _arg in "$@"; do
  case "$_arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

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

# Dá para abrir prompts? Exige terminal e respeita --no-interactive (CI/automação).
# Vale também quando o script foi chamado com flags num terminal.
can_prompt() {
  [ -t 0 ] && [ "$NO_INTERACTIVE" != true ]
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

# Pasta real do script, seguindo links simbólicos (o install.sh cria o comando
# generate_pr como link). readlink sem -f para funcionar também no macOS.
_script_path="${BASH_SOURCE[0]}"
while [ -L "$_script_path" ]; do
  _link_dir="$(cd -P "$(dirname "$_script_path")" && pwd)"
  _script_path="$(readlink "$_script_path")"
  [[ "$_script_path" != /* ]] && _script_path="$_link_dir/$_script_path"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_script_path")" && pwd)"

# Configuração: GENERATE_PR_ENV_FILE, se definido; senão o .env ao lado do script e o
# ~/.config/generate_pr/.env (criado pelo install.sh). Um valor já carregado não é
# sobrescrito, então o primeiro arquivo vence.
CONFIG_ENV_FILE="$HOME/.config/generate_pr/.env"
if [ -n "${GENERATE_PR_ENV_FILE:-}" ]; then
  load_env_file "$GENERATE_PR_ENV_FILE"
else
  load_env_file "$SCRIPT_DIR/.env"
  load_env_file "$CONFIG_ENV_FILE"
fi

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

# Primeira letra maiúscula. Substitui o ${var^}, que não existe no bash 3.2 do macOS.
ucfirst() {
  printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"
}

# Rótulo legível para logs (ex.: "Claude · opus via claude CLI").
ai_model_label() {
  local via
  if [ "$AI_PROVIDER" = claude ]; then
    [ -n "$ANTHROPIC_API_KEY" ] && via="API da Anthropic" || via="claude CLI"
  else
    [ -n "$GEMINI_API_KEY_RESOLVED" ] && via="API REST" || via="gemini CLI"
  fi
  printf '%s · %s via %s' "$(ucfirst "$AI_PROVIDER")" "$(ai_model)" "$via"
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

# ID da tarefa no ClickUp a partir do nome da branch: um trecho de 9 caracteres
# alfanuméricos, com pelo menos um dígito, entre separadores (/ - _ .). Funciona em
# qualquer posição: feat/868gfh2k9, dhr-feat/novaatualizacao-868kut8jj, CU-868kut8jj.
# Com mais de um candidato, prefere o que começa com 86 (padrão dos IDs atuais).
detect_clickup_id() {
  local token first=""
  local -a tokens
  IFS='/._-' read -r -a tokens <<< "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for token in "${tokens[@]}"; do
    case "$token" in *[0-9]*) ;; *) continue ;; esac
    [[ "$token" =~ ^[0-9a-z]{9}$ ]] || continue
    if [[ "$token" == 86* ]]; then
      printf '%s' "$token"
      return 0
    fi
    [ -z "$first" ] && first="$token"
  done
  printf '%s' "$first"
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

# Papel e critérios de qualidade, enviados como system prompt nos três caminhos
# (API do Gemini, API da Anthropic e claude CLI). As regras de formato do template
# ficam no fim do prompt (build_prompt).
SYSTEM_PROMPT='Você escreve descrições de Pull Request para uma equipe de desenvolvimento. Quem lê é a pessoa que vai revisar o PR: ela precisa entender rápido o que mudou, por que mudou e onde prestar atenção.

Como escrever:
- Comece pelo porquê e pelo impacto (o problema resolvido ou o comportamento novo); depois, o que foi feito.
- Agrupe as mudanças por assunto. Não narre arquivo por arquivo nem repita o diff.
- Aponte o que pede atenção na revisão: riscos, mudanças de contrato ou de API, migrações, variáveis de ambiente ou configurações novas, dependências adicionadas.
- Seja conciso e específico. Prefira tópicos curtos a parágrafos longos e evite frases genéricas como "melhora a qualidade do código".
- Escreva em português do Brasil. Nomes de arquivos, funções, variáveis e comandos vão entre crases.

Fontes:
- Use só o diff, as mensagens de commit, o contexto do autor e a descrição atual do PR (quando houver). O contexto do autor é autoritativo e prevalece sobre o que você deduzir do diff.
- Não invente motivações, números, tarefas ou passos que essas fontes não sustentem. Se o porquê não estiver claro, descreva o que mudou sem especular.

Responda somente com o Markdown do template preenchido, sem texto antes ou depois e sem cercas de código em volta.'

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
  if ! jq -n --rawfile t "$prompt_file" --arg s "$SYSTEM_PROMPT" \
    '{systemInstruction:{parts:[{text:$s}]}, contents:[{role:"user", parts:[{text:$t}]}]}' > "$payload_file"; then
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

  if ! jq -n --rawfile t "$prompt_file" --arg m "$model" --arg s "$SYSTEM_PROMPT" --argjson fb "$fallback" \
    '{model:$m, max_tokens:16000, system:$s, messages:[{role:"user", content:$t}]}
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
# logada. Sem ferramentas e com o SYSTEM_PROMPT: o modelo só devolve o texto.
generate_via_claude_cli() {
  local prompt="$1" model="$2" out rc=0

  out=$(printf '%s' "$prompt" | claude -p \
    --model "$model" \
    --tools "" \
    --no-session-persistence \
    --output-format text \
    --system-prompt "$SYSTEM_PROMPT" \
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
    --selected "$(ucfirst "$AI_PROVIDER")"); then
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
    --verify)
      VERIFY_HOOKS=true
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
      ui_log warn "Argumento desconhecido ignorado: $1 (veja ${0##*/} --help)"
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

# O PR sai de uma branch de trabalho: nunca de main/master/release nem de HEAD destacado.
case "$CURRENT_BRANCH" in
  HEAD)
    ui_log error "HEAD destacado: faça checkout da branch de trabalho antes de abrir o PR."
    exit 1
    ;;
  main|master|release)
    ui_log error "Você está na branch '$CURRENT_BRANCH'. O PR precisa sair de uma branch de trabalho."
    exit 1
    ;;
esac

# Alterações não commitadas não vão para o PR (o script só envia commits).
_dirty=$(git status --porcelain)
if [ -n "$_dirty" ]; then
  ui_log warn "Há alterações não commitadas. Elas NÃO entram no PR:"
  printf '%s\n' "$_dirty" | head -n 10 | sed 's/^/    /'
  [ "$(printf '%s\n' "$_dirty" | wc -l)" -gt 10 ] && echo "    …"
  if can_prompt && ! ui_confirm "Continuar mesmo assim?"; then
    ui_log info "Faça o commit das alterações e rode de novo."
    exit 0
  fi
fi

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

DIFF_EXCLUDES=(
  ':(exclude)*package-lock.json'
  ':(exclude)*yarn.lock'
  ':(exclude)dist/'
  ':(exclude)build/'
  ':(exclude)node_modules/'
  ':(exclude)vendor/'
  ':(exclude)*.min.js'
  ':(exclude)*.min.css'
  ':(exclude)*.map'
  ':(exclude)*.png'
  ':(exclude)*.jpg'
  ':(exclude)*.jpeg'
  ':(exclude)*.gif'
  ':(exclude)*.svg'
  ':(exclude)*.pdf'
  ':(exclude)*.sqlite'
  ':(exclude)*.db'
)
GIT_DIFF=$(git diff "origin/$DIFF_BRANCH...HEAD" -- . "${DIFF_EXCLUDES[@]}")

if [ -z "$GIT_DIFF" ]; then
  ui_log warn "Nenhum diff relevante encontrado."
  exit 0
fi

# Visão geral dos arquivos e mensagens de commit: ajudam o modelo a entender o escopo
# e o porquê, que o diff sozinho não mostra. Trailers (Co-Authored-By etc.) são ruído.
GIT_STAT=$(git diff --stat=200 "origin/$DIFF_BRANCH...HEAD" -- . "${DIFF_EXCLUDES[@]}")
GIT_COMMITS=$(git log --no-merges --reverse -n 50 --format='* %s%n%w(0,2,2)%b' \
  "origin/$DIFF_BRANCH..HEAD" \
  | grep -viE '^[[:space:]]*(co-authored-by|signed-off-by):' \
  | sed '/^[[:space:]]*$/d' || true)

# Template (usa o do repositório; se não existir, cai no template padrão embutido)
if [ -f ".github/pull_request_template.md" ]; then
  TEMPLATE_PR=$(cat .github/pull_request_template.md)
else
  ui_log warn "Template .github/pull_request_template.md não encontrado — usando template padrão."
  TEMPLATE_PR="$DEFAULT_TEMPLATE"
fi

CLICKUP_ID=$(detect_clickup_id "$CURRENT_BRANCH")

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
# Por padrão os hooks de pre-push são pulados (alguns demoram e travam o push).
# Com --verify eles rodam, sem spinner, para que a saída deles fique visível.
if [ "$VERIFY_HOOKS" = true ]; then
  ui_log info "Enviando a branch para o remoto (com os hooks de pre-push)..."
  git push -u origin "$CURRENT_BRANCH"
else
  ui_spin "Garantindo que a branch está no remoto..." \
    git push -u --no-verify origin "$CURRENT_BRANCH"
fi

ui_log info "🔎 Verificando se já existe PR..."

PR_TITLE="$(ucfirst "$CURRENT_BRANCH")"
PR_NUMBER=$(gh pr list --head "$CURRENT_BRANCH" --base "$TARGET_BRANCH" --state open --json number --jq '.[0].number')

PR_CREATED=false
if [ -n "$PR_NUMBER" ]; then
  ui_log info "✅ PR já existe (#$PR_NUMBER)."
else
  PR_CREATED=true
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
    printf '%s\n\n%s' "$SYSTEM_PROMPT" "$prompt" | node --max-old-space-size=8192 "$(which gemini)" -m "$GEMINI_MODEL" 2>/dev/null
  fi
}

# Falhas seguidas no mesmo modelo antes de oferecer a troca.
MAX_ATTEMPTS_PER_MODEL=2

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

# Descrição que o PR já tem (PR reaproveitado ou --edit). Vai para o prompt, para o
# modelo manter o que o autor acrescentou à mão, e serve de base para preservar os
# checkboxes marcados. O template puro não conta como descrição.
CURRENT_BODY=""
if [ "$PR_CREATED" != true ]; then
  CURRENT_BODY=$(gh pr view "$PR_NUMBER" --json body --jq .body | tr -d '\r')
  if [ "$CURRENT_BODY" = "$TEMPLATE_PR" ]; then
    CURRENT_BODY=""
  fi
fi

# Monta o prompt: primeiro os dados, cada um na sua tag (o diff tem linhas "---", que
# confundiriam separadores), e as instruções no fim. Papel e critérios de qualidade
# ficam no SYSTEM_PROMPT.
build_prompt() {
  printf '<commits>\n%s\n</commits>\n\n' "${GIT_COMMITS:-(sem mensagens de commit)}"
  printf '<arquivos_alterados>\n%s\n</arquivos_alterados>\n\n' "$GIT_STAT"
  printf '<diff>\n%s\n</diff>\n\n' "$GIT_DIFF"
  if [ -n "$EXTRA_CONTEXT" ]; then
    printf '<contexto_do_autor>\n%s\n</contexto_do_autor>\n\n' "$EXTRA_CONTEXT"
  fi
  if [ -n "$CURRENT_BODY" ]; then
    printf '<descricao_atual>\n%s\n</descricao_atual>\n\n' "$CURRENT_BODY"
  fi
  printf '<template>\n%s\n</template>\n\n' "$TEMPLATE_PR"
  cat <<'EOF'
Preencha o <template> com a descrição deste Pull Request:

1. Mantenha todos os títulos, seções e subtópicos do template, na mesma ordem e com o mesmo texto, mesmo que alguma seção fique vazia.
2. Em listas de checkbox que classificam a mudança (como "Tipo de mudança"), marque com [x] as opções que o diff confirma e deixe as outras desmarcadas.
3. Não preencha a seção "## 📌 Checklist de Qualidade": ela é do autor. Copie-a exatamente como está no template.
4. Nos passos de teste, sugira validações manuais que decorram do diff e do contexto do autor.
EOF
  if [ -n "$CURRENT_BODY" ]; then
    cat <<'EOF'
5. A <descricao_atual> é a que o PR tem hoje e pode estar desatualizada. Reescreva a partir do diff, mas mantenha o que o autor acrescentou à mão e o diff não mostra, como imagens, links, observações e passos de teste específicos.
EOF
  fi
}

mkdir -p "$CACHE_DIR"
# sha256sum (Linux) ou shasum (macOS).
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}
# Arquivo de cache para o provedor/modelo e o prompt atuais. O prompt inclui diff,
# commits, contexto, template e descrição atual, então qualquer mudança neles (ou nas
# instruções) gera uma descrição nova.
cache_file() {
  printf '%s/%s' "$CACHE_DIR" \
    "$(printf '%s\n%s\n%s\n%s' "$CURRENT_BRANCH" "$AI_PROVIDER:$(ai_model)" "$SYSTEM_PROMPT" "$PROMPT" \
      | sha256 | cut -d' ' -f1)"
}

# Mantém marcados ([x]) os checkboxes que já estavam marcados na descrição atual (ex.: o
# checklist preenchido pelo autor) quando o mesmo item volta desmarcado na nova.
keep_checked_items() {
  local current_file new_file
  current_file=$(mktemp)
  new_file=$(mktemp)
  printf '%s\n' "$1" > "$current_file"
  printf '%s\n' "$2" > "$new_file"
  awk '
    { sub(/\r$/, "") }
    NR == FNR {
      if (match($0, /^[ \t]*[-*] \[[xX]\] /)) checked[substr($0, RLENGTH + 1)] = 1
      next
    }
    match($0, /^[ \t]*[-*] \[ \] /) && (substr($0, RLENGTH + 1) in checked) {
      $0 = substr($0, 1, RLENGTH - 3) "x] " substr($0, RLENGTH + 1)
    }
    { print }
  ' "$current_file" "$new_file"
  rm -f "$current_file" "$new_file"
}

# Obtém a descrição para o prompt atual (do cache ou gerando) e a guarda em PR_BODY.
# Uso: obtain_body [true = ignora o cache]. Em caso de falha, PR_BODY não muda.
obtain_body() {
  local skip_cache="${1:-false}" cache
  PROMPT=$(build_prompt)
  cache=$(cache_file)
  if [ "$skip_cache" != true ] && [ -f "$cache" ]; then
    ui_log info "💾 Usando a descrição em cache (prompt e modelo não mudaram)..."
    PR_BODY=$(cat "$cache")
  else
    generate_pr_body "$PROMPT" || return 1
    # O modelo pode ter sido trocado durante a geração: salva na chave do modelo final.
    printf '%s' "$PR_BODY" > "$(cache_file)"
  fi
  if [ -n "$CURRENT_BODY" ]; then
    PR_BODY=$(keep_checked_items "$CURRENT_BODY" "$PR_BODY")
  fi
}

# Abre a descrição no editor do usuário ($VISUAL, $EDITOR ou vi).
edit_body() {
  local dir file
  dir=$(mktemp -d)
  file="$dir/descricao-pr.md"
  printf '%s\n' "$PR_BODY" > "$file"
  if ${VISUAL:-${EDITOR:-vi}} "$file" < /dev/tty > /dev/tty; then
    PR_BODY=$(cat "$file")
  else
    ui_log warn "O editor terminou com erro; mantendo a versão anterior."
  fi
  rm -rf "$dir"
}

# Mostra a descrição e pergunta o que fazer. Retorna 0 para aplicar e 1 para não
# aplicar. Esc/Ctrl+C encerra sem mexer no PR (o contexto extra continua salvo).
review_body() {
  local action
  while true; do
    printf '%s\n' "$PR_BODY" | gum format
    action=$(gum choose \
      "Aplicar no PR #$PR_NUMBER" \
      "Editar antes de aplicar" \
      "Gerar de novo" \
      "Não aplicar (o PR fica como está)" \
      --header "Descrição gerada ($(ai_model_label))") || _abort_cancel
    case "$action" in
      Aplicar*) return 0 ;;
      Editar*)  edit_body ;;
      Gerar*)
        if ui_confirm "Ajustar o contexto extra antes de gerar de novo?" --default=false; then
          EXTRA_CONTEXT=$(edit_context "$EXTRA_CONTEXT") || _abort_cancel
          if [ -n "$EXTRA_CONTEXT" ]; then
            save_context
          fi
        fi
        obtain_body true || ui_log warn "Não foi possível gerar de novo; mantendo a versão anterior."
        ;;
      *) return 1 ;;
    esac
  done
}

PR_BODY=""
if ! obtain_body; then
  ui_log error "Não foi possível gerar a descrição com a IA."
  ui_log info "O PR #$PR_NUMBER já foi criado com o template. Rode o script novamente mais tarde para preencher a descrição."
  if [ -n "$EXTRA_CONTEXT" ]; then
    ui_log info "💾 Contexto extra salvo em $(context_file) — será oferecido na próxima execução interativa."
  fi
fi

# Com alguém no terminal, a descrição passa por revisão antes de ir para o PR.
APPLY_BODY=false
if [ -n "$PR_BODY" ]; then
  if ! can_prompt; then
    APPLY_BODY=true
  elif review_body; then
    APPLY_BODY=true
  else
    ui_log info "Descrição não aplicada; o PR #$PR_NUMBER ficou como estava."
  fi
fi

# ─────────────────────────────────────────────────────────────
# 3º) Atualiza o corpo do PR com a descrição gerada (se aprovada)
# ─────────────────────────────────────────────────────────────
if [ "$APPLY_BODY" = true ]; then
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

PR_URL=$(gh pr view "$PR_NUMBER" --json url --jq .url 2>/dev/null || true)
ui_success "PR #$PR_NUMBER pronto!"
if [ -n "$PR_URL" ]; then
  ui_log info "🔗 $PR_URL"
  if can_prompt && ui_confirm "Abrir o PR no navegador?" --default=false; then
    gh pr view "$PR_NUMBER" --web > /dev/null 2>&1 || ui_log warn "Não foi possível abrir o navegador."
  fi
fi
