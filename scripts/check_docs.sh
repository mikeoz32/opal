#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${root}/scripts/build_docs.sh"

test -f "${root}/build/docs/site/index.html"
test -f "${root}/build/docs/site/api/index.html"
