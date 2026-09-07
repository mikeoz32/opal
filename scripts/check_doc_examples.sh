#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_dir="${CRYSTAL_CACHE_DIR:-${root}/build/docs/crystal-cache}"
crystal_path="${root}/src:${root}/lib:$(crystal env CRYSTAL_PATH)"

mkdir -p "${cache_dir}"

examples=(
  examples/documentation/application_guide.cr
  examples/documentation/dependency_injection_guide.cr
  examples/documentation/first_api.cr
  examples/documentation/http_controllers_guide.cr
  examples/documentation/installation.cr
  examples/documentation/live_view_counter.cr
  examples/documentation/todo_data.cr
  examples/documentation/websockets_guide.cr
  examples/api_route_di_example.cr
  examples/application_bootstrap_example.cr
  examples/di_lifecycle_example.cr
  examples/handler_stack_example.cr
  examples/http_execution_pipeline_example.cr
  examples/router_example.cr
  examples/data_layer_sqlite/src/data_layer_example_cli.cr
  examples/data_layer_sqlite/src/data_layer_example_http_cli.cr
  examples/data_layer_sqlite/src/data_layer_example_application_cli.cr
  examples/live_view_counter/src/live_view_counter_example.cr
  examples/todo_api_sqlite/src/todo_api_sqlite_example.cr
  examples/ui_showcase/src/ui_showcase_example.cr
)

for example in "${examples[@]}"; do
  echo "Checking ${example}"
  CRYSTAL_PATH="${crystal_path}" \
    CRYSTAL_CACHE_DIR="${cache_dir}" \
    crystal build --no-codegen "${root}/${example}"
done
