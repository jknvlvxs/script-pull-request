# Changelog

Todas as mudanças relevantes do `generate_pr.sh` são documentadas neste arquivo.

O formato segue o [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/). Como o
script não tem versões numeradas, as entradas são agrupadas por data; mudanças ainda
não mescladas na `main` ficam em **[Não lançado]**.

Categorias usadas: **Adicionado**, **Alterado**, **Corrigido**, **Removido**.

## [Não lançado]

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
