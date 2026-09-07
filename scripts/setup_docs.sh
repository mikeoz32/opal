#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
venv="${root}/.venv-docs"

python3 -m venv "${venv}"
"${venv}/bin/python" -m pip install -r "${root}/requirements-docs.txt"

echo "Documentation environment: ${venv}"
