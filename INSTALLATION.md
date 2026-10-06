# Instalação

Como instalar o `generate_pr` (comando de terminal) e a skill `/pullrequest` do
Claude Code. Para usar depois de instalado, veja o [README](README.md).

---

## Sumário

- [Antes de começar](#antes-de-começar)
- [Instalação rápida (recomendada)](#instalação-rápida-recomendada)
- [O que o instalador faz](#o-que-o-instalador-faz)
- [Configuração](#configuração)
  - [Claude (padrão)](#claude-padrão)
  - [Gemini](#gemini)
  - [Variáveis de configuração](#variáveis-de-configuração)
- [Atualizar e desinstalar](#atualizar-e-desinstalar)
- [Instalação manual](#instalação-manual)
- [Problemas na instalação](#problemas-na-instalação)

---

## Antes de começar

- **Sistema:** Linux (Debian/Ubuntu), macOS com [Homebrew](https://brew.sh) ou
  Windows pelo [WSL](https://learn.microsoft.com/windows/wsl/install) com Ubuntu. Em
  outras distribuições, use a [instalação manual](#instalação-manual).
- **Acesso ao repositório:** ele é privado; peça para ser adicionado antes de clonar.
- **GitHub:** uma conta com acesso aos repositórios em que você vai abrir PRs.
- **Claude Code** (recomendado): é o provedor padrão das descrições e não precisa de
  API key. Sem ele, dá para usar o Gemini com uma key (veja [Gemini](#gemini)).

Dependências (o instalador confere todas e instala as que faltarem):

| Ferramenta | Obrigatória | Para quê |
|------------|-------------|----------|
| `git`      | sim         | diff, branch, push |
| `gh` ([GitHub CLI](https://cli.github.com/)) | sim | criar/atualizar PR (precisa estar autenticado: `gh auth login`) |
| `curl`     | sim         | chamadas às APIs do Gemini e da Anthropic |
| `jq`       | sim         | parsing das respostas da API |
| `gum` ([Charm gum](https://github.com/charmbracelet/gum)) | sim | UI interativa (navegação por setas, busca incremental) e feedback visual |
| `claude` CLI ([Claude Code](https://claude.com/claude-code)) | recomendada | gera as descrições com o Claude Opus (o padrão) quando **não** há `ANTHROPIC_API_KEY` (precisa estar logado) |
| `node` + `gemini` CLI | opcional | usado apenas como fallback quando **não** há `GEMINI_API_KEY` |

---

## Instalação rápida (recomendada)

1. **Clone o repositório.** A pasta pode ser qualquer uma; os comandos abaixo usam
   `~/script-pull-request`.

   ```bash
   git clone git@github.com:jknvlvxs/script-pull-request.git ~/script-pull-request
   # sem chave SSH no GitHub, com o gh já logado:
   # gh repo clone jknvlvxs/script-pull-request ~/script-pull-request
   ```

2. **Rode o instalador.** Ele mostra o que falta e pergunta antes de instalar
   (`--yes` instala sem perguntar; no apt, pede a senha do `sudo`).

   ```bash
   ~/script-pull-request/install.sh
   ```

3. **Faça os logins** que o instalador indicar:
   - GitHub: `gh auth login` (o instalador oferece rodar na hora);
   - Claude Code: instale com `curl -fsSL https://claude.ai/install.sh | bash` e
     rode `claude` uma vez para logar. Sem ele, configure o [Gemini](#gemini).

4. **Confira a instalação** num terminal novo:

   ```bash
   generate_pr --help
   ```

   Se aparecer a lista de opções, o comando está no `PATH`. Para a skill, abra uma
   sessão **nova** do Claude Code e digite `/pullrequest`.

5. **Primeiro uso:** numa branch de trabalho de qualquer repositório, rode
   `generate_pr`. Na primeira vez, o script pergunta se deve publicar as descrições
   sem revisar e se deve abrir o PR no navegador (Enter aceita o padrão: sim). As
   respostas ficam gravadas; veja as [variáveis de configuração](#variáveis-de-configuração)
   para mudar depois.

---

## O que o instalador faz

O `install.sh` pode ser rodado de novo quando quiser: ele só refaz o que falta e
nunca sobrescreve a sua configuração.

| Passo | O que acontece |
|-------|----------------|
| Dependências | Confere `git`, `curl`, `jq`, `gh` e `gum` e instala as que faltam pelo `brew` ou pelo `apt` (no apt, adiciona os repositórios oficiais do GitHub CLI e da Charm). |
| Contas | Verifica se o `gh` está logado (oferece `gh auth login`) e se o Claude Code está instalado. |
| Configuração | Cria `~/.config/generate_pr/.env` a partir do `.env.example`, sem sobrescrever um que já exista. |
| Comando | Cria o link `~/.local/bin/generate_pr` → `generate_pr.sh` do clone (avisa se `~/.local/bin` não estiver no `PATH`). |
| Skill | Cria o link `~/.claude/skills/pullrequest` → `skills/pullrequest` do clone. |

Como comando e skill são links para o clone, um `git pull` atualiza os dois.

Opções:

| Opção | O que faz |
|-------|-----------|
| `-y`, `--yes` | Instala as dependências sem perguntar. |
| `--uninstall` | Remove o comando e a skill (só se forem links para este clone) e mantém a configuração. |
| `-h`, `--help` | Mostra a ajuda. |

Para criar o comando em outra pasta, defina `GENERATE_PR_BIN_DIR`:

```bash
GENERATE_PR_BIN_DIR=~/bin ~/script-pull-request/install.sh
```

---

## Configuração

Com o Claude Code instalado e logado, nada precisa ser configurado: o padrão é o
**Claude Opus** pelo `claude` CLI. Para trocar provedor, modelo ou usar API keys,
edite o `~/.config/generate_pr/.env` (criado pelo instalador; o
[`.env.example`](.env.example) explica cada variável).

Ordem de precedência:

1. Flags (`--model`, `--provider`) e a seleção do modo interativo
2. Variáveis de ambiente
3. `GENERATE_PR_ENV_FILE`, se definida (aí só esse arquivo é lido); senão o `.env` ao
   lado do script e depois o `~/.config/generate_pr/.env`
4. Defaults do código

Os arquivos `.env` são ignorados pelo git (ver `.gitignore`).

> ⚠️ **Nunca** coloque uma key dentro do `generate_pr.sh` — o arquivo é versionado.

### Claude (padrão)

Há dois jeitos de usar o Claude, escolhidos automaticamente:

1. **`claude` CLI** — sem `ANTHROPIC_API_KEY`, o script chama `claude -p` (Claude
   Code) sem ferramentas, usando a conta em que você já está logado. Não precisa de
   configuração além do `claude` instalado e autenticado.
2. **Messages API** — se `ANTHROPIC_API_KEY` estiver definida (env ou `.env`). Os
   apelidos viram os IDs `claude-sonnet-5`, `claude-opus-5-5` e `claude-haiku-4-5`.

```dotenv
# opcional: troque o padrão (Claude Opus)
AI_PROVIDER=claude           # claude | gemini
CLAUDE_MODEL=opus            # opus | sonnet | haiku (ou um ID completo)
ANTHROPIC_API_KEY=           # opcional; sem ela o claude CLI é usado
```

### Gemini

O script usa a Generative Language API (Google AI Studio). A key é resolvida nesta
ordem:

1. `GEMINI_API_KEY` (variável de ambiente ou `.env`, na ordem acima)
2. Arquivo `~/.config/generate_pr/api_key`

> Se **nenhuma** key for encontrada, o script tenta usar o `gemini` CLI como fallback.

Para usar o Gemini como padrão, no `~/.config/generate_pr/.env`:

```dotenv
AI_PROVIDER=gemini
GEMINI_API_KEY=sua_key_aqui
GEMINI_MODEL=gemini-3.5-flash
```

Alternativas para a key:

```bash
# via env var (ex.: no ~/.zshrc)
export GEMINI_API_KEY="sua_key_aqui"

# via arquivo dedicado
mkdir -p ~/.config/generate_pr
printf '%s' "sua_key_aqui" > ~/.config/generate_pr/api_key
chmod 600 ~/.config/generate_pr/api_key
```

### Variáveis de configuração

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `AI_PROVIDER` | `claude` | Provedor padrão: `claude` ou `gemini`. |
| `CLAUDE_MODEL` | `opus` | Modelo Claude padrão: `sonnet`, `opus`, `haiku` ou um ID completo (ex.: `claude-opus-5-5`). |
| `ANTHROPIC_API_KEY` | — | API key da Anthropic. Sem ela, o Claude roda pelo `claude` CLI. |
| `GEMINI_API_KEY` | — | API key do Gemini (Google AI Studio). |
| `GEMINI_MODEL` | `gemini-3.5-flash` | Modelo Gemini padrão. |
| `AUTO_PUBLISH_DESCRIPTION` | `true` | Publica a descrição direto no PR. Com `false`, mostra para revisão antes (só num terminal). Perguntada uma vez se não estiver definida. |
| `OPEN_PR_IN_BROWSER` | `true` | Abre o PR no navegador ao terminar (só num terminal, nunca com `--no-interactive`). Perguntada uma vez se não estiver definida. |
| `GENERATE_PR_ENV_FILE` | — | Caminho de um `.env` alternativo. Quando definida, substitui o `.env` ao lado do script e o `~/.config/generate_pr/.env`. |
| `GENERATE_PR_BIN_DIR` | `~/.local/bin` | Só para o `install.sh`: pasta onde o comando `generate_pr` é criado. |

---

## Atualizar e desinstalar

**Atualizar:**

```bash
git -C ~/script-pull-request pull
```

Comando e skill são links para o clone, então os dois se atualizam juntos. Se o
[CHANGELOG](CHANGELOG.md) mencionar mudanças no instalador, rode o `install.sh` de
novo.

**Desinstalar:**

```bash
~/script-pull-request/install.sh --uninstall
```

Remove o comando e a skill e mantém a configuração em `~/.config/generate_pr/` e o
cache em `~/.cache/generate_pr/` (apague as pastas se quiser).

---

## Instalação manual

Para outras distribuições, ou se preferir fazer cada passo:

1. **`gum`** — Debian/Ubuntu (apt):

   ```bash
   sudo mkdir -p /etc/apt/keyrings
   curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
   echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
     | sudo tee /etc/apt/sources.list.d/charm.list
   sudo apt update && sudo apt install gum
   ```

   Outras opções: `brew install gum` (macOS / Linuxbrew) ou
   `go install github.com/charmbracelet/gum@latest`.

2. **`gh` e `jq`** — `sudo apt install gh jq` ou `brew install gh jq`; depois
   `gh auth login`.

3. **Comando, skill e configuração**, a partir da pasta do clone:

   ```bash
   chmod +x generate_pr.sh
   mkdir -p ~/.local/bin ~/.claude/skills ~/.config/generate_pr
   ln -s "$PWD/generate_pr.sh" ~/.local/bin/generate_pr
   ln -s "$PWD/skills/pullrequest" ~/.claude/skills/pullrequest
   cp .env.example ~/.config/generate_pr/.env && chmod 600 ~/.config/generate_pr/.env
   ```

4. **Confira** com `generate_pr --help`, como no
   [passo 4 da instalação rápida](#instalação-rápida-recomendada).

---

## Problemas na instalação

**`Dependência ausente: gum` (ou gh/jq/curl/git)**
Rode o `install.sh` de novo ou instale a ferramenta pela
[instalação manual](#instalação-manual). O script só roda com todas as dependências
obrigatórias presentes.

**`generate_pr: command not found`** (no terminal ou no `/pullrequest`)
O comando não foi criado ou o `~/.local/bin` não está no `PATH`. Rode o `install.sh`
de novo; se ele avisar sobre o `PATH`, adicione ao `~/.zshrc` ou `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Depois abra um terminal novo (ou uma sessão nova do Claude Code).

**A skill `/pullrequest` não aparece no Claude Code**
As skills são carregadas quando a sessão começa: abra uma sessão nova. Confira se o
link existe com `ls -l ~/.claude/skills/pullrequest`. Se o instalador avisou que
`~/.claude/skills/pullrequest já existe e não é um link`, renomeie ou apague essa
pasta e rode o `install.sh` de novo.

**`Permission denied (publickey)` ao clonar**
Sua chave SSH não está cadastrada no GitHub. Clone com
`gh repo clone jknvlvxs/script-pull-request ~/script-pull-request` (depois de
`gh auth login`) ou [cadastre uma chave SSH](https://docs.github.com/authentication/connecting-to-github-with-ssh).
Se aparecer `Repository not found`, você ainda não tem acesso ao repositório.

**No macOS: `Instale manualmente` / Homebrew não encontrado**
O instalador usa o Homebrew no macOS. Instale-o em [brew.sh](https://brew.sh) e rode
o `install.sh` de novo.

**`Claude indisponível: defina ANTHROPIC_API_KEY ou instale o claude CLI`**
O provedor é o Claude (o padrão), mas não há key nem `claude` no `PATH`. Instale o
Claude Code e rode `claude` uma vez para logar, defina `ANTHROPIC_API_KEY` ou mude
para o [Gemini](#gemini).

**`Gemini indisponível: defina GEMINI_API_KEY ou instale o gemini CLI`**
O provedor é o Gemini (via `AI_PROVIDER`, `--provider` ou `--model gemini-*`), mas não
há key nem `gemini` CLI. Configure a key (veja [Gemini](#gemini)).

**PR não foi criado / falha de autenticação do `gh`**
Rode `gh auth login` e confirme que sua conta tem acesso ao repositório.
