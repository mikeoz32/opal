# Get started

This section takes an application from an empty Crystal project to HTTP, Data,
and LiveView. The tutorials are intentionally incremental: each one uses a
real repository example as its executable counterpart.

| Goal | Start here | What it teaches |
| --- | --- | --- |
| Add Opal to a Crystal shard | [Install Opal](installation.md) | dependencies and module imports |
| Serve JSON | [First HTTP API](../tutorials/first-api.md) | controllers, DI, request binding |
| Persist records | [Todo API](../tutorials/todo-api.md) | entities, migrations, repositories, transactions |
| Render an interactive page | [LiveView counter](../tutorials/live-view-counter.md) | lifecycle, events, `phx-*` bindings |

!!! tip "Use the examples as executable documentation"

    `examples/todo_api_sqlite`, `examples/data_layer_sqlite`,
    `examples/live_view_counter`, and `examples/ui_showcase` have their own
    shard files and specs. The site explains the contracts; the examples prove
    that the full application compiles and runs.
