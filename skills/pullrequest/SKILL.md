---
name: pullrequest
description: Cria ou atualiza o Pull Request da branch atual com o generate_pr — push, PR com o template, descrição gerada por IA (Gemini ou Claude) a partir do diff e link do ClickUp. Use quando o usuário digitar /pullrequest.
argument-hint: "[hotfix | base <branch>] [draft] [edit] [sonnet | opus | haiku | gemini-…] [contexto livre]"
disable-model-invocation: true
allowed-tools:
  - Bash(generate_pr *)
  - Bash(git branch *)
  - Bash(git status *)
  - Bash(git rev-parse *)
  - Bash(git log *)
  - Bash(git diff *)
  - Bash(gh pr view *)
  - Read(~/.cache/generate_pr/**)
---

# /pullrequest

Wrapper do comando `generate_pr` (instalado pelo `install.sh` do repositório
script-pull-request) para o Claude Code. Aqui não há terminal para o
`gum`, então o script roda **sempre** com `--no-interactive`, e as perguntas que ele
faria no terminal são feitas por você, com AskUserQuestion.

**Quem escreve a descrição é o script** (com o modelo escolhido). Não redija nem edite o
corpo do PR por conta própria; o seu papel é coletar as opções, montar o contexto extra,
rodar o script e tratar o resultado.

Argumentos: `$ARGUMENTS`

## Estado atual

- Branch: !`git branch --show-current`
- Raiz do repositório: !`git rev-parse --show-toplevel`
- Alterações não commitadas (vazio = nenhuma): !`git status --short`
- PR da branch: !`gh pr view --json number,state,baseRefName,isDraft,url 2>/dev/null || echo "nenhum"`

Só conta como PR aberto se `state` for `OPEN`; um PR `MERGED` ou `CLOSED` equivale a
"nenhum".

## 1. Pré-checagens

- Se a branch atual for `main`, `master` ou `release`, pare e explique que o PR sai de
  uma branch de trabalho.
- Se houver alterações não commitadas, avise que elas **não** entram no PR (o script só
  envia commits) e pergunte se deve seguir mesmo assim. Não faça commit por conta
  própria.

## 2. Opções a partir dos argumentos

Interprete `$ARGUMENTS` (ordem livre, maiúsculas indiferentes):

| Argumento | Flag do script |
|-----------|----------------|
| `hotfix` | `--hotfix` (destino `main`/`master`) |
| `base <branch>` / `para <branch>` | `--base <branch>` |
| `diff <branch>` | `--diff <branch>` (branch de comparação do diff) |
| `draft` / `rascunho` | `--draft` |
| `edit` / `editar` / `atualizar` | `--edit` (só regenera a descrição do PR aberto) |
| `sonnet`, `opus`, `haiku`, `claude-*`, `gemini-*` | `--model <nome>` |
| qualquer outro texto | vira contexto extra (passo 3) |

## 3. Perguntas (uma única chamada de AskUserQuestion)

Pergunte **só o que os argumentos não definiram**, tudo na mesma chamada:

1. **Destino** — se há PR aberto, a primeira opção é "Atualizar o PR #N (→ base)"
   (Recommended), que vira `--edit`. Depois: "Normal → release", "Hotfix →
   main/master". Outra branch de destino chega pelo "Other".
2. **Draft** — só quando não há PR aberto: "Não" / "Sim, como rascunho".
3. **Modelo** — "Padrão configurado" (sem `--model`; Claude Opus, salvo outro no
   `.env`), "Claude Sonnet", "Claude Opus", "Claude Haiku". Um modelo Gemini
   específico chega pelo "Other".
4. **Contexto extra** — só se houver o que propor (veja abaixo). Opção "Usar este
   contexto" com o texto proposto no `preview`, e "Sem contexto adicional". Um texto
   próprio chega pelo "Other".

### Contexto extra proposto

O contexto é informação que **não está no diff**: motivação, decisões, o que foi
descartado, como testar. Monte a proposta a partir de:

- o texto livre dos argumentos;
- o que foi discutido nesta conversa sobre as mudanças da branch (o porquê, não um
  resumo do diff) — se ajudar, consulte `git log`/`git diff` da branch;
- o contexto salvo de uma execução anterior que falhou, se existir, em
  `~/.cache/generate_pr/context/<nome da pasta da raiz do repositório>/<branch com / trocado por __>.md`
  — por exemplo `feat/868gfh2k9` no repositório `api` vira
  `~/.cache/generate_pr/context/api/feat__868gfh2k9.md`. Leia com a ferramenta Read;
  se não existir, siga sem ele.

Seja curto (tópicos). Se não houver nada além do diff, pule a pergunta 4 e rode sem
contexto.

## 4. Rodar o script

Grave o contexto escolhido num arquivo temporário (no diretório de scratchpad da sessão,
se houver). Rode o script chamando-o exatamente por `generate_pr` (é o que o
`allowed-tools` libera), com timeout de 600000 ms, porque a geração pode levar alguns
minutos. Uma branch de destino digitada no "Other" vira `--base <branch>`.

```bash
generate_pr --no-interactive [--edit | --hotfix | --base <branch>] [--draft] [--diff <branch>] [--model <nome>] [--context-file <arquivo>]
```

O script faz o push da branch, cria o PR com o template (ou reaproveita o aberto para o
mesmo destino), gera a descrição e aplica via `gh api`. A linha `🤖 Modelo:` do log
mostra o modelo usado.

## 5. Tratar o resultado

- **`Não foi possível gerar a descrição com a IA`** — o modelo falhou 2 vezes seguidas;
  o PR já existe, com o template. Pergunte com AskUserQuestion para qual modelo trocar
  (Sonnet, Opus, Haiku, um Gemini flash — sem repetir o que falhou) ou se deve
  desistir. Para trocar, rode de novo com `--edit --model <novo>` e o **mesmo**
  `--context-file`. Repita até funcionar ou o usuário desistir.
- **`PR #N pronto!`** sem o erro acima — sucesso. Pegue os dados com
  `gh pr view --json url,title,baseRefName,isDraft`.
- **`generate_pr: command not found`** — o comando não está instalado (ou
  `~/.local/bin` não está no PATH). Peça para rodar o `install.sh` do repositório
  script-pull-request e abrir uma nova sessão; não procure o script em outro lugar.
- **Outros erros** (`Nenhum diff relevante`, branch de destino inexistente, provedor
  indisponível, falha no push ou no `gh`) — relate a mensagem do script e o que fazer;
  não tente contornar editando o PR à mão.

No fim, responda em poucas linhas: link do PR, destino, se é draft, modelo que gerou a
descrição e se houve contexto extra. Sugira revisar a descrição no GitHub.
