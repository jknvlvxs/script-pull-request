# Changelog

Todas as mudanças relevantes do `generate_pr.sh` são documentadas neste arquivo.

O formato segue o [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/). Como o
script não tem versões numeradas, as entradas são agrupadas por data; mudanças ainda
não mescladas na `main` ficam em **[Não lançado]**.

Categorias usadas: **Adicionado**, **Alterado**, **Corrigido**, **Removido**.

## [Não lançado]

### Adicionado

- Geração da descrição com **Claude**, escolhendo entre **Sonnet**, **Opus** e
  **Haiku**. Usa a Messages API quando há `ANTHROPIC_API_KEY` e, sem ela, o `claude`
  CLI (Claude Code) em modo não interativo, sem ferramentas, com a conta já logada.
- Passo "Provedor e modelo" no modo interativo: escolhe Gemini ou Claude (só aparecem
  os provedores configurados) e depois o modelo.
- Flag `--provider` e variáveis `AI_PROVIDER`, `CLAUDE_MODEL` e `ANTHROPIC_API_KEY`.
  `--model` deduz o provedor pelo nome (`gemini-*` → Gemini; `sonnet`/`opus`/`haiku`/
  `claude-*` → Claude).
- `--list-models` também mostra os apelidos do Claude.
- Checagem antecipada: se o provedor escolhido não tem key nem CLI, o script para antes
  de criar ou alterar o PR.
- No Opus 5 via API, recusas dos classificadores de segurança passam pelo fallback
  server-side da Anthropic (`fallbacks: "default"`), que refaz a chamada em outro
  modelo.

### Alterado

- A lista de modelos Gemini (seleção interativa e `--list-models`) mostra apenas os
  modelos *flash* de texto, do mais novo para o mais antigo. Variantes pro, lite,
  image, tts e afins ficam de fora (ainda é possível usá-las via `--model`).
- `.env.example` sugere um modelo flash (`gemini-3.5-flash`) em vez do
  `gemini-2.5-pro`.
- A chave do cache passa a incluir o provedor (`provedor:modelo`), então descrições
  em cache de versões anteriores não são reaproveitadas.

### Corrigido

- A listagem de modelos lia só a primeira página da API (50 modelos) e podia omitir
  modelos novos; agora pede `pageSize=1000`.
- O `GEMINI_MODEL` definido no `.env` era ignorado: o default do código era atribuído
  antes de carregar o `.env`, e o loader não sobrescreve variáveis já definidas. O
  default agora é aplicado depois do `.env`.

## 2026-09-24

### Alterado

- Modelo Gemini padrão passa a ser `gemini-3.5-flash`.
- O payload da API REST do Gemini é montado e enviado a partir de arquivos temporários
  (`jq --rawfile` + `curl --data-binary @arquivo`), evitando estourar o `ARG_MAX` do
  shell com diffs grandes.

## 2026-06-18

### Adicionado

- Interface interativa com [`gum`](https://github.com/charmbracelet/gum): navegação por
  setas, busca incremental de branches/modelos e editor multilinha para o contexto,
  substituindo os menus numéricos do `select`.
- Detecção de PR já aberto da branch atual, com a opção de editar o existente (gerar
  nova descrição) ou criar um novo PR para outro destino.
- Opção "Outra" no tipo de PR e flag `--base`/`--target` para escolher manualmente a
  branch de destino (validada contra o remoto).
- Template de PR padrão embutido, usado quando o repositório não tem
  `.github/pull_request_template.md`.
- Geração via API REST do Gemini (curl + jq), com fallback para o `gemini` CLI quando
  não há API key.
- Carregamento automático do `.env` ao lado do script (ou `GENERATE_PR_ENV_FILE`) e
  leitura da key em `~/.config/generate_pr/api_key`.
- Flags `--model`, `--context`, `--context-file`, `--list-models`, `-i/--interactive` e
  `--no-interactive`.
- Cache das descrições geradas em `~/.cache/generate_pr/` (branch + modelo + contexto +
  diff).
- O PR é criado primeiro com o template e a descrição da IA é aplicada depois via
  `PATCH` — se a IA falhar, o PR continua válido.
- `README.md` com instalação, uso, flags e solução de problemas.

### Alterado

- Modelo padrão trocado para `gemini-2.5-flash` (o free tier do `gemini-2.5-pro` foi
  removido).

### Corrigido

- Erro `NumericalClassifierStrategy` do roteador interno do `gemini` CLI, contornado
  com a chamada direta à API REST.
- A checagem de PR existente passa a filtrar pela branch de destino (`--base`),
  evitando reusar um PR aberto para outro destino.
- O `--value` do `gum filter` pré-filtrava a lista de modelos.

## 2026-04-20

### Adicionado

- Versão inicial do `generate_pr.sh`: gera a descrição do PR com o `gemini` CLI a
  partir do `git diff` e cria o PR com o `gh`.
