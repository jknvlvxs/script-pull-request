# generate_pr

Gera (ou atualiza) um Pull Request no GitHub a partir da branch atual, criando o PR
primeiro com o template e depois preenchendo a descrição automaticamente com IA
(Claude ou Gemini) a partir do `git diff`.

> **Instalação:** veja o [INSTALLATION.md](INSTALLATION.md). Um comando instala o
> script, as dependências e a skill `/pullrequest` do Claude Code.

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
- **Detecção de ClickUp** pelo nome da branch (em qualquer posição), com link
  automático no template.
- **Publicação direta ou com revisão** — por padrão a descrição vai direto para o
  PR e o PR abre no navegador; com `AUTO_PUBLISH_DESCRIPTION=false`, ela é mostrada
  antes para aplicar, editar no seu editor ou gerar de novo.
- **Edições preservadas** — ao atualizar um PR, os checkboxes já marcados (como o
  checklist) continuam marcados, e o que o autor escreveu à mão vai para o prompt.
- **Cache** por branch + modelo + prompt (diff, commits, contexto, template).

> Histórico de mudanças: veja o [CHANGELOG.md](CHANGELOG.md).

---

## Sumário

- [Uso](#uso)
  - [Modo interativo](#modo-interativo)
  - [Modo não-interativo (flags)](#modo-não-interativo-flags)
  - [Dentro do Claude Code (`/pullrequest`)](#dentro-do-claude-code-pullrequest)
- [Opções / Flags](#opções--flags)
- [Como funciona o fluxo](#como-funciona-o-fluxo)
- [Cache](#cache)
- [Solução de problemas](#solução-de-problemas)
- [Licença](#licença)

---

## Uso

Execute a partir do diretório do repositório, **na branch** que deseja abrir o PR:

```bash
generate_pr
```

`generate_pr --help` lista todas as opções. Provedor, modelo e preferências ficam no
`~/.config/generate_pr/.env` (veja a
[configuração](INSTALLATION.md#configuração)).

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
6. **Publicação** — por padrão a descrição gerada vai direto para o PR e, no fim, o
   PR abre no navegador. Com `AUTO_PUBLISH_DESCRIPTION=false`, a descrição é mostrada
   formatada antes e o script pergunta: **aplicar no PR**, **editar antes de
   aplicar** (abre o `$VISUAL` ou `$EDITOR`; sem eles, o `vi`), **gerar de novo**
   (com a opção de ajustar o contexto) ou **não aplicar**.

**Preferências perguntadas uma vez.** Na primeira execução num terminal, o script
pergunta se deve publicar sem revisar (`AUTO_PUBLISH_DESCRIPTION`) e se deve abrir o
PR no navegador (`OPEN_PR_IN_BROWSER`); Enter aceita o padrão (sim). As respostas
ficam no `~/.config/generate_pr/.env` e não são perguntadas de novo — para mudar,
edite o valor lá (veja as
[variáveis de configuração](INSTALLATION.md#variáveis-de-configuração)). Elas valem também quando o script roda com flags num terminal. Com
`--no-interactive` (e na skill `/pullrequest`) nada é perguntado: a descrição é
publicada direto e o navegador não abre.

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
script numa sessão do Claude Code. Ela é instalada junto com o comando (veja o
[INSTALLATION.md](INSTALLATION.md)) e se atualiza com o `git pull` do clone.

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
| `--verify` | — | Roda os hooks de pre-push no `git push`. Por padrão eles são pulados (`--no-verify`), porque alguns demoram e travam o push. |
| `--edit` | — | Atualiza só a descrição do PR aberto da branch, qualquer que seja o destino dele (ignora `--hotfix`/`--base`). Erro se não houver PR aberto. |
| `--diff [branch]` | branch (opcional) | Compara o diff com a branch informada; sem valor, usa `origin/HEAD`. |
| `--model <nome>` | nome do modelo | Define o modelo. `gemini-*` usa o Gemini; `sonnet`, `opus`, `haiku` ou `claude-*` usam o Claude; outros nomes valem para o provedor atual. |
| `--provider <nome>` | `gemini` ou `claude` | Define o provedor de IA (normalmente desnecessário: `--model` já o deduz). |
| `--context "<texto>"` | texto | Adiciona contexto ao prompt (pode ser combinado com `--context-file`). |
| `--context-file <arquivo>` | caminho | Adiciona o conteúdo de um arquivo como contexto. |
| `--list-models` | — | Lista os modelos Gemini *flash* disponíveis (mais novo primeiro) e os apelidos do Claude, e sai. |
| `-i`, `--interactive` | — | Força o modo interativo. |
| `--no-interactive` | — | Força o modo não-interativo. |
| `-h`, `--help` | — | Mostra todas as opções, com exemplos, e sai. Funciona mesmo sem as dependências instaladas. |

> Um argumento desconhecido (ex.: `--darft`) gera um aviso e é ignorado; o script
> continua.

---

## Como funciona o fluxo

1. Carrega `.env` e resolve a API key.
2. `git fetch origin` e determina a branch padrão (`main`/`master`).
3. Recusa rodar em `main`, `master`, `release` ou com HEAD destacado, e avisa se há
   alterações não commitadas (no terminal, pergunta se deve continuar).
4. (Interativo) coleta tipo, draft, branch de comparação, modelo e contexto.
5. Gera o `git diff` (ignorando lockfiles, builds, binários e imagens), o resumo dos
   arquivos alterados (`--stat`) e as mensagens dos commits da branch.
6. Lê `.github/pull_request_template.md` (ou usa um **template padrão embutido** se o
   arquivo não existir) e injeta o link do ClickUp. O ID é um trecho de 9 caracteres
   alfanuméricos (com pelo menos um dígito) em qualquer posição do nome da branch:
   `feat/868gfh2k9`, `dhr-feat/novaatualizacao-868kut8jj`, `fix/CU-868kut8jj`.
7. Faz o push e **cria o PR** (ou detecta um existente) já com o template — com
   `--assignee @me`.
8. Gera a **descrição com IA** com o provedor escolhido. O prompt traz commits,
   arquivos alterados, diff, contexto do autor e, ao atualizar um PR, a descrição
   atual — cada parte numa tag (`<diff>`, `<commits>`…) — e as regras do template no
   fim; o papel e os critérios de uma boa descrição vão como system prompt. Gemini:
   API REST, ou `gemini` CLI sem key. Claude: Messages API, ou `claude` CLI sem key.
   Após **2 falhas seguidas** no mesmo modelo, pergunta (via `gum choose`) se quer
   **trocar de modelo**, tentar de novo ou desistir — o contexto extra já digitado é
   mantido. Sem terminal (CI) ou com `--no-interactive`, desiste direto. O resultado
   é salvo em cache.
9. Ao atualizar um PR, os checkboxes que já estavam marcados continuam marcados.
10. Com `AUTO_PUBLISH_DESCRIPTION=false` (num terminal), mostra a descrição para
    **revisão** (aplicar, editar, gerar de novo ou não aplicar).
11. **Atualiza** o corpo do PR via `gh api PATCH`, mostra a URL e, num terminal,
    abre o PR no navegador (`OPEN_PR_IN_BROWSER`).

Se a etapa 8 falhar, o PR continua válido com o template — basta rodar de novo. O
contexto extra fica salvo e é oferecido de volta na próxima execução interativa.

---

## Cache

As descrições geradas ficam em `~/.cache/generate_pr/`, com chave derivada de
**branch + provedor/modelo + prompt completo** (instruções, diff, commits, contexto,
template e descrição atual do PR). Mudar qualquer um desses regenera a descrição;
caso contrário, o conteúdo em cache é reutilizado (evita chamadas repetidas à IA).
"Gerar de novo", na revisão, ignora o cache.

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

> Problemas de instalação (dependência ausente, `command not found`, skill que não
> aparece, provedor indisponível, login do `gh`) estão no
> [INSTALLATION.md](INSTALLATION.md#problemas-na-instalação).

**`Você está na branch 'main'` / `HEAD destacado`**
O PR precisa sair de uma branch de trabalho. Faça checkout da sua branch (ou crie
uma com `git switch -c <nome>`) e rode de novo.

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

**`claude CLI: ...` / `API Claude: ...`**
Mensagem de erro repassada do Claude (modelo inválido, sessão expirada, key inválida,
limite de uso). Para o CLI, confira se `claude -p "oi"` funciona no terminal.

**PR não foi criado / falha de autenticação do `gh`**
Rode `gh auth login` e confirme que sua conta tem acesso ao repositório.

---

## Licença

Distribuído sob a licença MIT. Veja o [LICENSE](LICENSE).
