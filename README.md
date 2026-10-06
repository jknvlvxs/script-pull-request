# generate_pr.sh

Gera (ou atualiza) um Pull Request no GitHub a partir da branch atual, criando o PR
primeiro com o template e depois preenchendo a descrição automaticamente com IA
(Gemini ou Claude) a partir do `git diff`.

Principais recursos:

- **PR primeiro, descrição depois** — o PR é criado/encontrado já com o template; a
  descrição gerada pela IA é aplicada em seguida via `PATCH`. Se a IA falhar, o PR
  permanece com o template (nada se perde).
- **Geração via API REST do Gemini** (curl + jq), evitando o roteador interno do
  `gemini` CLI (que causava o erro `NumericalClassifierStrategy`). Com fallback para o
  `gemini` CLI quando não há API key.
- **Geração com Claude** (Opus por padrão, ou Sonnet/Haiku) — via Messages API quando
  há `ANTHROPIC_API_KEY`, ou via `claude` CLI (Claude Code) usando a conta já logada.
- **Seleção dinâmica de modelos** consultando a API (apenas modelos Gemini *flash*).
- **Troca de modelo em caso de falha** — após 2 falhas seguidas no mesmo modelo, o
  script pergunta se quer trocar de modelo (ou de provedor), tentar de novo ou desistir.
- **Contexto adicional** ao prompt, além do diff — salvo por branch até a descrição
  ser aplicada, para não precisar redigitá-lo se a geração falhar.
- **Experiência interativa moderna** com [`gum`](https://github.com/charmbracelet/gum)
  (navegação por setas, busca incremental, sem menus numéricos).
- **Skill `/pullrequest` para o Claude Code** — roda o script de dentro de uma sessão,
  com as perguntas feitas pelo Claude e o contexto extra montado a partir da conversa.
- **Detecção de ClickUp** pelo nome da branch, com link automático no template.
- **Cache** por branch + modelo + contexto + diff.

> Histórico de mudanças: veja o [CHANGELOG.md](CHANGELOG.md).

---

## Sumário

- [Pré-requisitos](#pré-requisitos)
- [Instalação](#instalação)
  - [Instalação rápida (recomendada)](#instalação-rápida-recomendada)
  - [Instalação manual](#instalação-manual)
- [Configuração](#configuração)
- [Uso](#uso)
  - [Modo interativo](#modo-interativo)
  - [Modo não-interativo (flags)](#modo-não-interativo-flags)
  - [Dentro do Claude Code (`/pullrequest`)](#dentro-do-claude-code-pullrequest)
- [Opções / Flags](#opções--flags)
- [Variáveis de ambiente](#variáveis-de-ambiente)
- [Como funciona o fluxo](#como-funciona-o-fluxo)
- [Cache](#cache)
- [Solução de problemas](#solução-de-problemas)

---

## Pré-requisitos

| Ferramenta | Obrigatória | Para quê |
|------------|-------------|----------|
| `git`      | sim         | diff, branch, push |
| `gh` ([GitHub CLI](https://cli.github.com/)) | sim | criar/atualizar PR (precisa estar autenticado: `gh auth login`) |
| `curl`     | sim         | chamadas às APIs do Gemini e da Anthropic |
| `jq`       | sim         | parsing das respostas da API |
| `gum` ([Charm gum](https://github.com/charmbracelet/gum)) | sim | UI interativa (navegação por setas, busca incremental) e feedback visual |
| `claude` CLI ([Claude Code](https://claude.com/claude-code)) | recomendada | gera as descrições com o Claude Opus (o padrão) quando **não** há `ANTHROPIC_API_KEY` (precisa estar logado) |
| `node` + `gemini` CLI | opcional | usado apenas como fallback quando **não** há `GEMINI_API_KEY` |

> O `install.sh` confere tudo isso e instala o que faltar. O script também verifica as
> dependências obrigatórias no início e **encerra com erro** se alguma estiver ausente.

---

## Instalação

### Instalação rápida (recomendada)

Funciona no Linux (Debian/Ubuntu, inclusive WSL) e no macOS (com
[Homebrew](https://brew.sh)).

1. **Clone o repositório.** Ele é privado: peça acesso antes. A pasta pode ser
   qualquer uma; os comandos abaixo usam `~/script-pull-request`.

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
     rode `claude` uma vez para logar. Ele é o provedor padrão das descrições; sem
     ele, configure o Gemini (veja [Configuração](#configuração)).

4. **Teste** numa branch de trabalho de qualquer repositório: rode `generate_pr` no
   terminal ou `/pullrequest` numa sessão **nova** do Claude Code.

O que o instalador faz (pode rodar de novo quando quiser; só refaz o que falta):

| Passo | O que acontece |
|-------|----------------|
| Dependências | Confere `git`, `curl`, `jq`, `gh` e `gum` e instala as que faltam pelo `brew` ou pelo `apt` (no apt, adiciona os repositórios oficiais do GitHub CLI e da Charm). |
| Contas | Verifica se o `gh` está logado (oferece `gh auth login`) e se o Claude Code está instalado. |
| Configuração | Cria `~/.config/generate_pr/.env` a partir do `.env.example`, sem sobrescrever um que já exista. |
| Comando | Cria o link `~/.local/bin/generate_pr` → `generate_pr.sh` do clone (avisa se `~/.local/bin` não estiver no `PATH`). |
| Skill | Cria o link `~/.claude/skills/pullrequest` → `skills/pullrequest` do clone. |

**Atualizar:** `git -C ~/script-pull-request pull`. Comando e skill são links para o
clone, então os dois se atualizam juntos.

**Desinstalar:** `~/script-pull-request/install.sh --uninstall` remove o comando e a
skill e mantém a configuração em `~/.config/generate_pr/`.

### Instalação manual

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

---

## Configuração

Com o Claude Code instalado e logado, nada precisa ser configurado: o padrão é o
**Claude Opus** pelo `claude` CLI. Para trocar provedor, modelo ou usar API keys,
edite o `~/.config/generate_pr/.env` (criado pelo instalador; o `.env.example` explica
cada variável).

Ordem de precedência das variáveis:

1. Flags (`--model`, `--provider`) e a seleção do modo interativo
2. Variáveis de ambiente
3. `GENERATE_PR_ENV_FILE`, se definida (aí só esse arquivo é lido); senão o `.env` ao
   lado do script e depois o `~/.config/generate_pr/.env`
4. Defaults do código

Os arquivos `.env` são ignorados pelo git (ver `.gitignore`).

### Gemini

O script usa a Generative Language API (Google AI Studio). A key é resolvida nesta
ordem de precedência:

1. `GEMINI_API_KEY` (variável de ambiente ou `.env`, na ordem acima)
2. Arquivo `~/.config/generate_pr/api_key`

> Se **nenhuma** key for encontrada, o script tenta usar o `gemini` CLI como fallback.

Para usar o Gemini como padrão, no `~/.config/generate_pr/.env`:

```dotenv
AI_PROVIDER=gemini
GEMINI_API_KEY=sua_key_aqui
GEMINI_MODEL=gemini-3.5-flash
```

### Alternativas

```bash
# via env var (ex.: no ~/.zshrc)
export GEMINI_API_KEY="sua_key_aqui"

# via arquivo dedicado
mkdir -p ~/.config/generate_pr
printf '%s' "sua_key_aqui" > ~/.config/generate_pr/api_key
chmod 600 ~/.config/generate_pr/api_key
```

### Claude

O Claude Opus é o provedor e modelo padrão. Há dois jeitos de usá-lo, escolhidos
automaticamente:

1. **Messages API** — se `ANTHROPIC_API_KEY` estiver definida (env ou `.env`). Os
   apelidos viram os IDs `claude-sonnet-5`, `claude-opus-5-5` e `claude-haiku-4-5`.
2. **`claude` CLI** — sem a key, o script chama `claude -p` (Claude Code) sem
   ferramentas, usando a conta em que você já está logado. Não precisa de configuração
   extra além de `claude` instalado e autenticado.

```dotenv
# opcional: troque o padrão (Claude Opus)
AI_PROVIDER=claude           # claude | gemini
CLAUDE_MODEL=opus            # opus | sonnet | haiku (ou um ID completo)
ANTHROPIC_API_KEY=           # opcional; sem ela o claude CLI é usado
```

> ⚠️ **Nunca** coloque a key dentro do `generate_pr.sh` — o arquivo é versionado.

---

## Uso

Execute a partir do diretório do repositório, **na branch** que deseja abrir o PR:

```bash
generate_pr
```

### Modo interativo

Acionado automaticamente quando o script roda **sem flags** em um terminal
(ou forçado com `-i`). Todas as escolhas são navegáveis por teclado (via `gum`):

0. **PR já existente** — se houver um PR aberto da branch atual, o script indica e
   pergunta via `gum choose` entre *editar o existente* (gerar nova descrição) ou
   *criar um novo PR* (para outra branch de destino). Ao editar, os passos 1 e 2
   (tipo/draft) são pulados, pois o destino já está fixado no PR.
1. **Tipo de PR** — `gum choose` (Normal → `release` / Hotfix → `main`/`master` /
   **Outra** → escolher a branch de destino via `gum filter`).
2. **Draft?** — `gum confirm` (Sim/Não).
3. **Branch de comparação** — `gum filter` com busca incremental sobre as branches
   remotas (Enter na opção "Usar base padrão" mantém o padrão).
4. **Provedor e modelo** — `gum choose` entre **Gemini** e **Claude** (só aparecem os
   provedores configurados). No Gemini, `gum filter` sobre os modelos *flash*
   disponíveis (a primeira opção mantém o `GEMINI_MODEL`); no Claude, `gum choose`
   entre **Sonnet**, **Opus** e **Haiku**.
5. **Contexto adicional** — `gum confirm` + editor multilinha `gum write`. Se uma
   execução anterior desta branch falhou, o contexto digitado nela é mostrado e o
   script oferece **usar**, **editar**, **escrever um novo** ou **descartar**.

### Modo não-interativo (flags)

Passar qualquer flag desativa o modo interativo (ideal para automação/CI):

```bash
# PR normal, modelo flash, com contexto inline
generate_pr --no-interactive --model gemini-2.5-flash --context "Foco no fix de timeout"

# Gerar a descrição com o Claude Opus
generate_pr --no-interactive --model opus

# Regenerar a descrição do PR já aberto desta branch
generate_pr --edit --model sonnet

# Hotfix em draft
generate_pr --hotfix --draft

# Comparar contra uma branch específica
generate_pr --diff develop

# Contexto vindo de arquivo
generate_pr --context-file ./notas-do-pr.md

# Apenas listar modelos disponíveis
generate_pr --list-models
```

A checagem de PR existente filtra pela branch de **destino**: se já houver um PR
aberto para o mesmo destino, ele é reutilizado e só a descrição é atualizada; se o
destino for diferente (ex.: `--hotfix` para `main` enquanto há um PR para `release`),
um novo PR é criado.

### Dentro do Claude Code (`/pullrequest`)

A skill em [`skills/pullrequest/SKILL.md`](skills/pullrequest/SKILL.md) permite usar o
script numa sessão do Claude Code. O `install.sh` já a instala, como um link para o
clone (a skill continua versionada aqui e se atualiza com o `git pull`). Ela chama o
comando `generate_pr`, então o `~/.local/bin` precisa estar no `PATH`.

Depois, na branch do PR, dentro do Claude Code:

```text
/pullrequest                          # pergunta destino, draft, modelo e contexto
/pullrequest hotfix draft opus        # sem perguntas sobre o que já foi dito
/pullrequest edit sonnet              # só regenera a descrição do PR aberto
/pullrequest o timeout vinha do retry sem backoff   # texto livre vira contexto
```

Como funciona:

- O Claude Code não tem terminal para o `gum`, então o script roda sempre com
  `--no-interactive`; as perguntas do modo interativo (destino, draft, modelo e
  contexto) são feitas pelo Claude numa única tela. Argumentos já informados não são
  perguntados.
- O **contexto extra** é proposto pelo Claude a partir da conversa (motivação,
  decisões, como testar), do texto livre dos argumentos e do contexto salvo de uma
  execução que falhou. Você vê a proposta antes e pode trocar ou dispensar.
- **Quem escreve a descrição continua sendo o script**, com o modelo escolhido. Se ele
  falhar 2 vezes seguidas, o Claude pergunta para qual modelo trocar e roda de novo com
  `--edit`, mantendo o contexto.
- A skill só roda quando você digita `/pullrequest` (`disable-model-invocation`), já que
  ela faz push e cria/altera o PR.

---

## Opções / Flags

| Flag | Argumento | Descrição |
|------|-----------|-----------|
| `--hotfix` | — | PR direcionado para `main`/`master` em vez de `release`. |
| `--base`, `--target` | branch | Define manualmente a branch de **destino** do PR (validada contra o remoto). |
| `--draft` | — | Cria o PR como rascunho. |
| `--edit` | — | Atualiza só a descrição do PR aberto da branch, qualquer que seja o destino dele (ignora `--hotfix`/`--base`). Erro se não houver PR aberto. |
| `--diff [branch]` | branch (opcional) | Compara o diff com a branch informada; sem valor, usa `origin/HEAD`. |
| `--model <nome>` | nome do modelo | Define o modelo. `gemini-*` usa o Gemini; `sonnet`, `opus`, `haiku` ou `claude-*` usam o Claude; outros nomes valem para o provedor atual. |
| `--provider <nome>` | `gemini` ou `claude` | Define o provedor de IA (normalmente desnecessário: `--model` já o deduz). |
| `--context "<texto>"` | texto | Adiciona contexto ao prompt (pode ser combinado com `--context-file`). |
| `--context-file <arquivo>` | caminho | Adiciona o conteúdo de um arquivo como contexto. |
| `--list-models` | — | Lista os modelos Gemini *flash* disponíveis (mais novo primeiro) e os apelidos do Claude, e sai. |
| `-i`, `--interactive` | — | Força o modo interativo. |
| `--no-interactive` | — | Força o modo não-interativo. |

> Qualquer flag desconhecida é ignorada silenciosamente.

---

## Variáveis de ambiente

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `GEMINI_API_KEY` | — | API key do Gemini (Google AI Studio). |
| `GEMINI_MODEL` | `gemini-3.5-flash` | Modelo Gemini padrão. Precedência: `--model`/seleção interativa > variável de ambiente > `.env` > default do código. |
| `AI_PROVIDER` | `claude` | Provedor padrão: `claude` ou `gemini`. |
| `CLAUDE_MODEL` | `opus` | Modelo Claude padrão: `sonnet`, `opus`, `haiku` ou um ID completo (ex.: `claude-opus-5-5`). |
| `ANTHROPIC_API_KEY` | — | API key da Anthropic. Sem ela, o Claude roda pelo `claude` CLI. |
| `GENERATE_PR_ENV_FILE` | — | Caminho de um `.env` alternativo. Quando definida, substitui o `.env` ao lado do script e o `~/.config/generate_pr/.env`. |

---

## Como funciona o fluxo

1. Carrega `.env` e resolve a API key.
2. `git fetch origin` e determina a branch padrão (`main`/`master`).
3. (Interativo) coleta tipo, draft, branch de comparação, modelo e contexto.
4. Gera o `git diff` (ignorando lockfiles, builds, binários e imagens).
5. Lê `.github/pull_request_template.md` (ou usa um **template padrão embutido** se o
   arquivo não existir) e injeta o link do ClickUp (se a branch tiver um ID no formato
   `feat/868gfh2k9`).
6. **Cria o PR** (ou detecta um existente) já com o template — com `--assignee @me`.
7. Gera a **descrição com IA** com o provedor escolhido. Gemini: API REST, ou `gemini`
   CLI sem key. Claude: Messages API, ou `claude` CLI sem key. Após **2 falhas
   seguidas** no mesmo modelo, pergunta (via `gum choose`) se quer **trocar de modelo**,
   tentar de novo ou desistir — o contexto extra já digitado é mantido. Sem terminal
   (CI) ou com `--no-interactive`, desiste direto. O resultado é salvo em cache.
8. **Atualiza** o corpo do PR via `gh api PATCH`.

Se a etapa 7 falhar, o PR continua válido com o template — basta rodar de novo. O
contexto extra fica salvo e é oferecido de volta na próxima execução interativa.

---

## Cache

As descrições geradas ficam em `~/.cache/generate_pr/`, com chave derivada de
**branch + provedor/modelo + contexto + diff**. Mudar qualquer um desses regenera a descrição;
caso contrário, o conteúdo em cache é reutilizado (evita chamadas repetidas à IA).

O contexto extra também fica salvo ali, em
`~/.cache/generate_pr/context/<repositório>/<branch>.md` (com `/` da branch trocado
por `__`). Ele é gravado assim que você o define e apagado quando a descrição é
aplicada ao PR; se a geração falhar (ou você cancelar), ele continua lá para a próxima
execução.

Para limpar:

```bash
rm -rf ~/.cache/generate_pr
```

---

## Solução de problemas

**`Dependência ausente: gum` (ou gh/jq/curl/git)**
Instale a ferramenta indicada (ver [Instalação](#instalação)). O script só roda com todas as dependências obrigatórias presentes.

**`generate_pr: command not found`** (no terminal ou no `/pullrequest`)
O comando não foi instalado ou o `~/.local/bin` não está no `PATH`. Rode o
`install.sh` de novo e siga o aviso sobre o `PATH`; depois abra um novo terminal (ou
uma nova sessão do Claude Code).

**`Nenhuma API key encontrada`**
Configure a key (ver [Configuração](#configuração)).

**`Template ... não encontrado — usando template padrão`**
Apenas um aviso: o repositório não tem `.github/pull_request_template.md`, então o
script usa um template padrão embutido. Adicione o arquivo se quiser um template próprio.

**`A branch de destino 'origin/<branch>' não existe no remoto`**
A branch alvo do PR (release/main ou a definida via `--base`/opção "Outra") não existe.
O script lista as branches disponíveis. Verifique o nome ou rode `git fetch origin`.

**Erro `NumericalClassifierStrategy` / "API returned invalid content"**
Era um problema do roteador interno do `gemini` CLI. Configure a `GEMINI_API_KEY` para
usar a API REST diretamente e contornar o roteador.

**`This model is currently experiencing high demand`**
O modelo escolhido está sobrecarregado. Após 2 tentativas o script oferece trocar de
modelo ali mesmo (por exemplo, outro flash ou o Claude). Em modo não interativo, rode de
novo com outro `--model` (ex.: `--model gemini-2.5-flash` ou `--model sonnet`).

**`Claude indisponível: defina ANTHROPIC_API_KEY ou instale o claude CLI`**
O provedor Claude foi escolhido (via `AI_PROVIDER`, `--provider` ou `--model`), mas não
há key nem `claude` no `PATH`. Instale o Claude Code e rode `claude` uma vez para logar,
ou defina `ANTHROPIC_API_KEY`.

**`claude CLI: ...` / `API Claude: ...`**
Mensagem de erro repassada do Claude (modelo inválido, sessão expirada, key inválida,
limite de uso). Para o CLI, confira se `claude -p "oi"` funciona no terminal.

**PR não foi criado / falha de autenticação do `gh`**
Rode `gh auth login` e confirme acesso ao repositório.
