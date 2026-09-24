# generate_pr.sh

Gera (ou atualiza) um Pull Request no GitHub a partir da branch atual, criando o PR
primeiro com o template e depois preenchendo a descrição automaticamente com IA
(Gemini) a partir do `git diff`.

Principais recursos:

- **PR primeiro, descrição depois** — o PR é criado/encontrado já com o template; a
  descrição gerada pela IA é aplicada em seguida via `PATCH`. Se a IA falhar, o PR
  permanece com o template (nada se perde).
- **Geração via API REST do Gemini** (curl + jq), evitando o roteador interno do
  `gemini` CLI (que causava o erro `NumericalClassifierStrategy`). Com fallback para o
  `gemini` CLI quando não há API key.
- **Seleção dinâmica de modelos** consultando a API.
- **Contexto adicional** ao prompt, além do diff.
- **Experiência interativa moderna** com [`gum`](https://github.com/charmbracelet/gum)
  (navegação por setas, busca incremental, sem menus numéricos).
- **Detecção de ClickUp** pelo nome da branch, com link automático no template.
- **Cache** por branch + modelo + contexto + diff.

> Histórico de mudanças: veja o [CHANGELOG.md](CHANGELOG.md).

---

## Sumário

- [Pré-requisitos](#pré-requisitos)
- [Instalação](#instalação)
- [Configuração da API key](#configuração-da-api-key)
- [Uso](#uso)
  - [Modo interativo](#modo-interativo)
  - [Modo não-interativo (flags)](#modo-não-interativo-flags)
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
| `curl`     | sim         | chamadas à API do Gemini |
| `jq`       | sim         | parsing das respostas da API |
| `gum` ([Charm gum](https://github.com/charmbracelet/gum)) | sim | UI interativa (navegação por setas, busca incremental) e feedback visual |
| `node` + `gemini` CLI | opcional | usado apenas como fallback quando **não** há API key |

> O script verifica as dependências obrigatórias no início e **encerra com erro** se
> alguma estiver ausente.

---

## Instalação

### 1. Clonar / posicionar o script

O script já vive em `~/scripts/generate_pr.sh`. Deixe-o executável:

```bash
chmod +x ~/scripts/generate_pr.sh
```

(Opcional) crie um alias no seu `~/.zshrc` / `~/.bashrc`:

```bash
alias gpr="~/scripts/generate_pr.sh"
```

### 2. Instalar o `gum`

**Debian/Ubuntu (apt):**

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
  | sudo tee /etc/apt/sources.list.d/charm.list
sudo apt update && sudo apt install gum
```

**Outras opções:**

```bash
brew install gum          # macOS / Linuxbrew
go install github.com/charmbracelet/gum@latest   # via Go
```

### 3. Instalar `gh` e `jq` (se faltarem)

```bash
sudo apt install gh jq      # Debian/Ubuntu
gh auth login               # autenticar no GitHub
```

---

## Configuração da API key

O script usa a Generative Language API (Google AI Studio). A key é resolvida nesta
ordem de precedência:

1. Variável de ambiente `GEMINI_API_KEY`
2. Arquivo `.env` ao lado do script (ou `GENERATE_PR_ENV_FILE`)
3. Arquivo `~/.config/generate_pr/api_key`

> Se **nenhuma** key for encontrada, o script tenta usar o `gemini` CLI como fallback.

### Opção recomendada: arquivo `.env`

```bash
cd ~/scripts
cp .env.example .env
# edite o .env e preencha GEMINI_API_KEY
```

O `.env` já é ignorado pelo git (ver `.gitignore`). Conteúdo:

```dotenv
GEMINI_API_KEY=sua_key_aqui
GEMINI_MODEL=gemini-3.7-flash
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

> ⚠️ **Nunca** coloque a key dentro do `generate_pr.sh` — o arquivo é versionado.

---

## Uso

Execute a partir do diretório do repositório, **na branch** que deseja abrir o PR:

```bash
~/scripts/generate_pr.sh
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
4. **Modelo Gemini** — `gum filter` com busca incremental sobre os modelos
   disponíveis (a primeira opção mantém o `GEMINI_MODEL` configurado).
5. **Contexto adicional** — `gum confirm` + editor multilinha `gum write`.

### Modo não-interativo (flags)

Passar qualquer flag desativa o modo interativo (ideal para automação/CI):

```bash
# PR normal, modelo flash, com contexto inline
~/scripts/generate_pr.sh --no-interactive --model gemini-2.5-flash --context "Foco no fix de timeout"

# Hotfix em draft
~/scripts/generate_pr.sh --hotfix --draft

# Comparar contra uma branch específica
~/scripts/generate_pr.sh --diff develop

# Contexto vindo de arquivo
~/scripts/generate_pr.sh --context-file ./notas-do-pr.md

# Apenas listar modelos disponíveis
~/scripts/generate_pr.sh --list-models
```

A checagem de PR existente filtra pela branch de **destino** (`--base`): se já houver
um PR aberto para o mesmo destino, ele é reutilizado e a descrição é atualizada; se o
destino for diferente (ex.: `--hotfix` para `main` enquanto há um PR para `release`),
um novo PR é criado.

---

## Opções / Flags

| Flag | Argumento | Descrição |
|------|-----------|-----------|
| `--hotfix` | — | PR direcionado para `main`/`master` em vez de `release`. |
| `--base`, `--target` | branch | Define manualmente a branch de **destino** do PR (validada contra o remoto). |
| `--draft` | — | Cria o PR como rascunho. |
| `--diff [branch]` | branch (opcional) | Compara o diff com a branch informada; sem valor, usa `origin/HEAD`. |
| `--model <nome>` | nome do modelo | Define o modelo Gemini (ex.: `gemini-2.5-flash`). |
| `--context "<texto>"` | texto | Adiciona contexto ao prompt (pode ser combinado com `--context-file`). |
| `--context-file <arquivo>` | caminho | Adiciona o conteúdo de um arquivo como contexto. |
| `--list-models` | — | Lista os modelos disponíveis (que suportam `generateContent`) e sai. |
| `-i`, `--interactive` | — | Força o modo interativo. |
| `--no-interactive` | — | Força o modo não-interativo. |

> Qualquer flag desconhecida é ignorada silenciosamente.

---

## Variáveis de ambiente

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `GEMINI_API_KEY` | — | API key do Gemini (Google AI Studio). |
| `GEMINI_MODEL` | `gemini-3.5-flash` | Modelo padrão. Precedência: `--model`/seleção interativa > variável de ambiente > `.env` > default do código. |
| `GENERATE_PR_ENV_FILE` | `<dir do script>/.env` | Caminho alternativo para o arquivo `.env`. |

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
7. Gera a **descrição com IA** (API REST do Gemini, 3 tentativas; fallback para o
   `gemini` CLI se não houver key). Resultado é salvo em cache.
8. **Atualiza** o corpo do PR via `gh api PATCH`.

Se a etapa 7 falhar, o PR continua válido com o template — basta rodar de novo.

---

## Cache

As descrições geradas ficam em `~/.cache/generate_pr/`, com chave derivada de
**branch + modelo + contexto + diff**. Mudar qualquer um desses regenera a descrição;
caso contrário, o conteúdo em cache é reutilizado (evita chamadas repetidas à IA).

Para limpar:

```bash
rm -rf ~/.cache/generate_pr
```

---

## Solução de problemas

**`Dependência ausente: gum` (ou gh/jq/curl/git)**
Instale a ferramenta indicada (ver [Instalação](#instalação)). O script só roda com todas as dependências obrigatórias presentes.

**`Nenhuma API key encontrada`**
Configure a key (ver [Configuração da API key](#configuração-da-api-key)).

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
O modelo escolhido está sobrecarregado. O script tenta 3 vezes; troque de modelo com
`--model` (ex.: `gemini-2.5-flash`) ou tente novamente mais tarde.

**PR não foi criado / falha de autenticação do `gh`**
Rode `gh auth login` e confirme acesso ao repositório.
