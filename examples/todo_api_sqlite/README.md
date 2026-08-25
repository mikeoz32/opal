# Todo API + SQLite Example

This is a standalone example project that uses:

- `opal` for routing/API handling
- `crystal-sqlite3` for persistence
- application and HTTP autoconfiguration
- annotation-based DI (`@[LF::DI::Service]`)
- lifecycle callbacks for opening/closing the SQLite database and creating the schema

## Run

From this directory:

```bash
shards install
crystal run src/todo_api_sqlite_example.cr
```

Server starts on `http://127.0.0.1:8083`.

`TodoApplication.run_http` discovers `TodoApi` at compile time, creates the
request-scope middleware, and owns server shutdown. `TodoApi` receives
`TodoRepository` through constructor injection. `TodoDatabase` receives
`LF::ConfigService`, opens `database.url`, and owns schema creation through its
DI lifecycle callback.

HTTP and database settings live in `config/application.yml`. Set
`OPAL_CONFIG=/path/to/application.yml` to select another file.

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
