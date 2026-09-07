#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
port="${OPAL_DOCS_PORT:-8000}"
docs_python="${OPAL_DOCS_PYTHON:-${root}/.venv-docs/bin/python}"

if [ ! -x "${docs_python}" ]; then
  docs_python="python3"
fi

"${root}/scripts/build_docs.sh"
exec "${docs_python}" -m http.server --directory "${root}/build/docs/site" "${port}"
