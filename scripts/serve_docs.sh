#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
port="${OPAL_DOCS_PORT:-8000}"

"${root}/scripts/build_docs.sh"
exec python3 -m http.server --directory "${root}/build/docs/site" "${port}"
