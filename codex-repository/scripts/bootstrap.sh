#!/usr/bin/env bash
set -euo pipefail

if [ ! -d .git ]; then
  git init >/dev/null
fi

if [ ! -f .gitignore ]; then
  cat > .gitignore <<'GI'
.env
.venv/
node_modules/
.DS_Store
GI
fi

echo "Codex repository initialized."
