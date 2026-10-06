#!/usr/bin/env bash
# Instalador do generate_pr: confere/instala as dependências, cria o comando
# `generate_pr`, a configuração em ~/.config/generate_pr/.env e a skill /pullrequest
# do Claude Code. Pode ser rodado de novo sem problemas (só refaz o que falta).
#
# Uso: ./install.sh [--yes] [--uninstall]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${GENERATE_PR_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="$HOME/.config/generate_pr"
SKILLS_DIR="$HOME/.claude/skills"

ASSUME_YES=false
UNINSTALL=false

usage() {
  cat <<EOF
Uso: ./install.sh [opções]

  -y, --yes      instala as dependências sem perguntar
  --uninstall    remove o comando generate_pr e a skill /pullrequest
                 (mantém a configuração em $CONFIG_DIR)
  -h, --help     mostra esta ajuda
EOF
}

for arg in "$@"; do
  case "$arg" in
    -y|--yes)    ASSUME_YES=true ;;
    --uninstall) UNINSTALL=true ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Opção desconhecida: $arg"; usage; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────────────────────
# Saída (sem gum: ele pode ser justamente o que falta instalar)
# ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  _b=$'\033[1m'; _g=$'\033[32m'; _y=$'\033[33m'; _r=$'\033[31m'; _0=$'\033[0m'
else
  _b=""; _g=""; _y=""; _r=""; _0=""
fi
step() { printf '\n%s==> %s%s\n' "$_b" "$1" "$_0"; }
ok()   { printf '  %s✔%s %s\n' "$_g" "$_0" "$1"; }
warn() { printf '  %s!%s %s\n' "$_y" "$_0" "$1"; }
fail() { printf '  %s✘%s %s\n' "$_r" "$_0" "$1"; }

# Há um terminal para perguntar? (falso em CI ou quando chamado por outra ferramenta)
has_tty() { ( exec < /dev/tty ) 2>/dev/null; }

# Pergunta S/n. Lê do terminal; sem terminal (e sem --yes) responde "não".
confirm() {
  local answer
  [ "$ASSUME_YES" = true ] && return 0
  has_tty || return 1
  printf '  %s [S/n] ' "$1"
  read -r answer < /dev/tty || return 1
  case "$answer" in
    ""|[sS]*|[yY]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Cria (ou atualiza) um link simbólico sem apagar arquivos ou pastas de verdade.
link() {
  local target="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    warn "$dest já existe e não é um link — deixei como está."
    return 1
  fi
  ln -sfn "$target" "$dest"
}

# Remove o link só se ele aponta para este repositório.
unlink_ours() {
  local dest="$1"
  if [ -L "$dest" ] && [[ "$(readlink "$dest")" == "$REPO_DIR"/* ]]; then
    rm "$dest"
    ok "Removido: $dest"
  fi
}

if [ "$UNINSTALL" = true ]; then
  step "Desinstalando"
  unlink_ours "$BIN_DIR/generate_pr"
  unlink_ours "$SKILLS_DIR/pullrequest"
  ok "Configuração mantida em $CONFIG_DIR (apague a pasta se quiser)."
  exit 0
fi

# ─────────────────────────────────────────────────────────────
# 1) Dependências
# ─────────────────────────────────────────────────────────────
step "Dependências"

REQUIRED=(git curl jq gh gum)
missing=()
for dep in "${REQUIRED[@]}"; do
  if command -v "$dep" >/dev/null 2>&1; then
    ok "$dep"
  else
    fail "$dep (falta)"
    missing+=("$dep")
  fi
done

# Repositório oficial do GitHub CLI no apt (o pacote das distros costuma ser antigo).
apt_add_gh_repo() {
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
}

# Repositório da Charm (gum) no apt.
apt_add_charm_repo() {
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg
  echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
    | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
}

install_missing() {
  if command -v brew >/dev/null 2>&1; then
    brew install "${missing[@]}"
  elif command -v apt-get >/dev/null 2>&1; then
    local dep
    for dep in "${missing[@]}"; do
      case "$dep" in
        gh)  apt_add_gh_repo ;;
        gum) apt_add_charm_repo ;;
      esac
    done
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}"
  else
    return 1
  fi
}

if [ ${#missing[@]} -gt 0 ]; then
  if ! command -v brew >/dev/null 2>&1 && ! command -v apt-get >/dev/null 2>&1; then
    fail "Instale manualmente: ${missing[*]}"
    if [ "$(uname -s)" = Darwin ]; then
      echo "  No macOS, instale o Homebrew (https://brew.sh) e rode este instalador de novo."
    else
      echo "  Veja a seção \"Instalação manual\" do README.md."
    fi
    exit 1
  fi
  if confirm "Instalar agora: ${missing[*]}?"; then
    install_missing
    for dep in "${missing[@]}"; do
      command -v "$dep" >/dev/null 2>&1 || { fail "$dep continua faltando"; exit 1; }
    done
    ok "Dependências instaladas."
  else
    fail "Sem as dependências o script não roda. Instale e rode o instalador de novo."
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────────
# 2) Contas: GitHub (obrigatório) e Claude Code (provedor padrão)
# ─────────────────────────────────────────────────────────────
step "Contas"

if gh auth status >/dev/null 2>&1; then
  ok "GitHub CLI autenticado."
elif has_tty && confirm "O gh não está autenticado. Fazer login agora (gh auth login)?"; then
  gh auth login < /dev/tty
else
  warn "Rode 'gh auth login' antes de usar o script."
fi

if command -v claude >/dev/null 2>&1; then
  ok "Claude Code encontrado (gera as descrições com o Claude Opus, o padrão)."
else
  warn "Claude Code não encontrado. Ele é o provedor padrão das descrições."
  echo "    Instale com:  curl -fsSL https://claude.ai/install.sh | bash"
  echo "    e rode 'claude' uma vez para fazer login."
  echo "    Sem ele, use o Gemini: GEMINI_API_KEY e AI_PROVIDER=gemini em $CONFIG_DIR/.env"
fi

# ─────────────────────────────────────────────────────────────
# 3) Configuração
# ─────────────────────────────────────────────────────────────
step "Configuração"

if [ -f "$CONFIG_DIR/.env" ]; then
  ok "Mantida: $CONFIG_DIR/.env"
else
  mkdir -p "$CONFIG_DIR"
  cp "$REPO_DIR/.env.example" "$CONFIG_DIR/.env"
  chmod 600 "$CONFIG_DIR/.env"
  ok "Criada: $CONFIG_DIR/.env (edite para trocar provedor, modelo ou keys)"
fi
[ -f "$REPO_DIR/.env" ] && warn "Há também um $REPO_DIR/.env; os valores dele têm prioridade."

# ─────────────────────────────────────────────────────────────
# 4) Comando generate_pr e skill /pullrequest
# ─────────────────────────────────────────────────────────────
step "Comando e skill"

chmod +x "$REPO_DIR/generate_pr.sh"
link "$REPO_DIR/generate_pr.sh" "$BIN_DIR/generate_pr" \
  && ok "Comando: $BIN_DIR/generate_pr"
link "$REPO_DIR/skills/pullrequest" "$SKILLS_DIR/pullrequest" \
  && ok "Skill /pullrequest: $SKILLS_DIR/pullrequest"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR não está no PATH. Adicione ao ~/.zshrc ou ~/.bashrc e abra um novo terminal:"
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

# ─────────────────────────────────────────────────────────────
step "Pronto!"
cat <<EOF
  No terminal, dentro de um repositório e na branch do PR:
    generate_pr                # modo interativo
  No Claude Code:
    /pullrequest               # (abra uma sessão nova para a skill aparecer)
  Para atualizar:
    git -C "$REPO_DIR" pull
EOF
