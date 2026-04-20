#!/bin/bash

set -e

echo "🔄 Buscando atualizações do repositório..."
git fetch origin

echo "🔎 Determinando a branch padrão..."

if git show-ref --verify --quiet refs/remotes/origin/main; then
  TARGET_BRANCH="main"
elif git show-ref --verify --quiet refs/remotes/origin/master; then
  TARGET_BRANCH="master"
else
  echo "❌ ERRO: Não foi possível encontrar 'origin/main' ou 'origin/master'."
  exit 1
fi

echo "✅ Branch padrão detectada: $TARGET_BRANCH"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "🌿 Branch atual: $CURRENT_BRANCH"

echo "🔍 Gerando diff filtrado..."

GIT_DIFF=$(git diff "origin/$TARGET_BRANCH...HEAD" -- . \
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
  echo "⚠️ Nenhum diff relevante encontrado."
  exit 0
fi

# Template
if [ ! -f ".github/pull_request_template.md" ]; then
  echo "❌ Template não encontrado em .github/pull_request_template.md"
  exit 1
fi

TEMPLATE_PR=$(cat .github/pull_request_template.md)

# Extrai ID do ClickUp (ex: feat/868gfh2k9)
CLICKUP_ID=$(echo "$CURRENT_BRANCH" | grep -oE '(feat|fix|chore|docs|style|refactor|perf|test|build|ci|hotfix|wip|impr|lint)/([0-9a-z]{9})' | cut -d'/' -f2 || true)

if [ -n "$CLICKUP_ID" ]; then
  CLICKUP_LINK="[Link para a tarefa no ClickUp](https://app.clickup.com/t/$CLICKUP_ID)"
  echo "🔗 ClickUp detectado: $CLICKUP_LINK"

  TEMPLATE_PR=$(echo "$TEMPLATE_PR" | sed "s|\[Link para a tarefa no ClickUp\]|$CLICKUP_LINK|g")
else
  echo "⚠️ Nenhum ID de ClickUp detectado na branch"
fi

CACHE_DIR="$HOME/.cache/generate_pr"
mkdir -p "$CACHE_DIR"
CACHE_KEY=$(printf '%s\n%s' "$CURRENT_BRANCH" "$GIT_DIFF" | sha256sum | cut -d' ' -f1)
CACHE_FILE="$CACHE_DIR/$CACHE_KEY"

if [ -f "$CACHE_FILE" ]; then
  echo "💾 Usando conteúdo do PR em cache (diff não mudou)..."
  PR_BODY=$(cat "$CACHE_FILE")
else
  echo "🧠 Gerando conteúdo do PR..."

  PROMPT=$(cat <<EOF
Você é um assistente de desenvolvimento sênior. Sua tarefa é preencher o template de Pull Request (PR) com base exclusivamente no git diff fornecido.

Regras obrigatórias:
1. Utilize somente informações presentes no git diff. Não faça suposições externas.
2. Retorne em formato Markdown contendo a ficha completa.
3. Não preencha a seção "## 📌 Checklist de Qualidade".
4. Mantenha todas as seções, subtópicos e checkboxes exatamente como estão, mesmo que vazios.
5. Não remova, renomeie ou reestruture títulos.
6. Sugira testes manuais apenas com base no diff.
7. Não adicione nenhum texto fora da ficha.

---
TEMPLATE:
$TEMPLATE_PR

---
DIFF:
$GIT_DIFF

---
RESULTADO:
EOF
)

  PR_BODY=$(echo "$PROMPT" | node --max-old-space-size=8192 $(which gemini))
  printf '%s' "$PR_BODY" > "$CACHE_FILE"
fi

echo "🔎 Verificando se já existe PR..."

PR_NUMBER=$(gh pr list --head "$CURRENT_BRANCH" --json number --jq '.[0].number')

TEMP_BODY_FILE=$(mktemp)
printf '%s' "$PR_BODY" > "$TEMP_BODY_FILE"

if [ -n "$PR_NUMBER" ]; then
  echo "✏️ PR já existe (#$PR_NUMBER). Atualizando descrição..."
  gh api --method PATCH "repos/{owner}/{repo}/pulls/$PR_NUMBER" --field "body=@$TEMP_BODY_FILE" > /dev/null
else
  echo "🆕 Criando novo PR..."
  gh pr create \
    --base "$TARGET_BRANCH" \
    --head "$CURRENT_BRANCH" \
    --title "$CURRENT_BRANCH" \
    --body-file "$TEMP_BODY_FILE"
fi

rm -f "$TEMP_BODY_FILE"

echo "✅ Processo finalizado!"