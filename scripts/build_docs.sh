#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${root}/build/docs"
site_dir="${build_dir}/site"
docs_ref="${OPAL_DOCS_REF:-$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse HEAD)}"

cd "${root}"

if ! python3 -c 'import mkdocs' >/dev/null 2>&1; then
  echo "mkdocs is not installed. Create .venv-docs and install requirements-docs.txt first." >&2
  exit 1
fi

if [ ! -d "${root}/lib" ]; then
  shards install
fi

rm -rf "${build_dir}"
mkdir -p "${site_dir}"

python3 -m mkdocs build --clean --config-file "${root}/mkdocs.yml"
crystal docs \
  --output "${site_dir}/api" \
  --project-name Opal \
  --project-version "$(sed -n 's/^version: "\(.*\)"/\1/p' "${root}/shard.yml")" \
  --source-refname "${docs_ref}" \
  --source-url-pattern "https://github.com/mikeoz32/opal/blob/%{refname}/%{path}#L%{line}"

echo "Documentation site: ${site_dir}/index.html"
echo "Crystal API reference: ${site_dir}/api/index.html"
