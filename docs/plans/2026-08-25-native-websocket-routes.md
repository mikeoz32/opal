# Native WebSocket Routes Implementation Plan

> **For Codex:** Implement this plan task-by-task with test-first development.

**Goal:** Add the first native WebSocket route slice to Opal using Crystal's
`HTTP::WebSocketHandler`, while preserving the existing HTTP router behavior.

**Architecture:** WebSocket is a first-class route type in `LF::HTTP::Router`.
The router matches the path, rejects HTTP/WS path conflicts at registration,
returns `426 Upgrade Required` for non-upgrade requests, and delegates valid
upgrades to Crystal's native handler. Connection DI, controller autoconfig,
and graceful shutdown are subsequent slices.

**Tech Stack:** Crystal 1.21, `HTTP::Server`, `HTTP::WebSocketHandler`,
`LF::Routing::Trie`, Crystal specs.

---

### Task 1: Define the route registration contract

**Files:**
- Modify: `spec/opal_spec.cr` in the `LF::HTTP::Router` describe block
- Modify: `src/opal/http/router.cr`

**Step 1: Write the failing tests**

Add tests showing that `router.ws(path) { |ws, params| ... }` registers a
WebSocket route and that registering an HTTP route and WebSocket route for the
same normalized path raises a route conflict error.

**Step 2: Run the focused specs**

Run: `CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec spec/opal_spec.cr --no-color`

Expected: FAIL because `Router#ws` and the conflict error do not exist.

**Step 3: Implement the minimal route bookkeeping**

Add a route-kind registry keyed by normalized path and expose `ws` with the
native socket callback shape. Keep existing HTTP method registration intact.

**Step 4: Run the focused specs**

Run the same command and expect the new tests to pass.

### Task 2: Add handshake dispatch and `426` behavior

**Files:**
- Modify: `spec/opal_spec.cr`
- Modify: `src/opal/http/router.cr`

**Step 1: Write the failing tests**

Add an HTTP request test for a known WebSocket path without upgrade headers;
expect status `426`, `Upgrade: websocket`, and a short response body. Add a
real loopback server/client test for a valid WebSocket upgrade and text callback
delivery, including route parameter capture.

**Step 2: Run the focused specs**

Run: `CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec spec/opal_spec.cr --no-color`

Expected: FAIL on the new `426` and handshake assertions.

**Step 3: Implement native handshake dispatch**

For a matched WebSocket route, instantiate/use Crystal's
`HTTP::WebSocketHandler` with the matched parameters captured for that request.
Let the stdlib handler own `ws.run`; Opal only invokes the route callback.

**Step 4: Run the focused specs**

Run the same command and expect all focused specs to pass.

### Task 3: Verify compatibility and commit the slice

**Files:**
- No additional production files expected.

**Step 1: Run the full suite**

Run: `CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color`

Expected: all existing and new specs pass.

**Step 2: Check the patch**

Run: `git diff --check` and inspect `git diff` for unrelated changes.

**Step 3: Commit**

Run: `git add src/opal/http/router.cr spec/opal_spec.cr docs/plans/2026-08-25-native-websocket-routes.md`

Run: `git commit -m "feat(http): add native websocket routes"`
