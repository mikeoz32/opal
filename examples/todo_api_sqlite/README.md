# Todo API + SQLite Example

This is a standalone example project that uses:

- `opal` for routing/API handling
- `crystal-sqlite3` for persistence
- annotation-based DI (`@[LF::DI::Service]`)
- lifecycle callbacks for opening/closing the SQLite database and creating the schema

## Run

From this directory:

```bash
shards install
crystal run src/todo_api_sqlite_example.cr
```

Server starts on `http://127.0.0.1:8083`.

The server stack includes a request-scope middleware that sets `context.state` for `LF::APIRoute` dependency resolution.
`TodoDatabase` and `TodoRepository` are registered through `LF::DI::AutowiredApplicationConfig`, so the example does not need manual `add_bean` calls.

## Endpoints

- `GET /todos`
- `GET /todos/:id`
- `POST /todos`
- `PUT /todos/:id`
- `DELETE /todos/:id`

## Request examples

Create:

```bash
curl -X POST http://127.0.0.1:8083/todos \
  -H "content-type: application/json" \
  -d '{"title":"write docs"}'
```

Update:

```bash
curl -X PUT http://127.0.0.1:8083/todos/1 \
  -H "content-type: application/json" \
  -d '{"completed":true}'
```
