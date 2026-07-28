# Data 05: EntityManager And Explicit Unit Of Work

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, `systematic-debugging`, and
> `verification-before-completion`.

**Goal:** Add transaction-local identity, entity lifecycle states, explicit
queued persistence, and deterministic flush behavior.

**Architecture:** `EntityManager` owns one `DB::Connection` inside one outer
transaction. It never owns the pool or commit/rollback. It tracks object
identity separately from database identity and allocates no dirty snapshots.

**Prerequisite:** Plans 03 and 04 are merged.

---

## Public API Increment

```crystal
source.transaction do |em|
  todo = Todo.new("Write tests")
  em.persist(todo)
  em.flush

  same_todo = em.find(Todo, todo.id.not_nil!)
  same_todo.same?(todo) # true

  todo.completed = true
  em.persist(todo)
end
```

## Task 1: Add Entity State And Identity Keys

**Files**

- Create: `src/opal/data/entity_state.cr`
- Create: `src/opal/data/entity_key.cr`
- Create: `src/opal/data/entity_manager.cr`
- Modify: `src/opal/data.cr`
- Create: `spec/data/entity_manager_state_spec.cr`

Internal state stores:

- object ID;
- entity type;
- lifecycle enum `New`, `Managed`, `Removed`, or `Detached`;
- converted database ID when known;
- loaded optimistic version when present;
- queued operation and first scheduling sequence.

Database identity key is entity type plus dumped ID. Object scheduling uses
`Reference#object_id`. Keep maps manager-local.

## Task 2: Implement State Transitions Without SQL

Write one failing example for every transition:

| State | `persist` | `remove` |
| --- | --- | --- |
| Unknown | New + INSERT | `EntityStateError` |
| New | coalesce INSERT | cancel + Detached |
| Managed | queue/coalesce UPDATE | queue DELETE |
| Removed | `EntityStateError` | no-op |
| Detached | `DetachedEntityError` | `DetachedEntityError` |

Additional cases:

- two unknown objects with the same assigned ID remain distinct until flush;
- repeated persist/remove does not duplicate queue entries;
- coalescing retains first queue position;
- close changes manager to terminal closed state;
- failed state is distinct from normal close.

Do not infer detached state from a non-nil ID.

## Task 3: Implement Find And Hydration

**Files**

- Create: `spec/data/entity_manager_find_spec.cr`

`find(T, id)`:

1. validates manager is usable;
2. converts and checks the identity map;
3. returns the existing object without SQL when found;
4. otherwise executes generated find-by-ID SQL;
5. hydrates exactly zero or one row;
6. registers a loaded object as Managed;
7. returns `nil` for no row;
8. raises if more than one row is returned.

Tests verify query count, same-object identity, assigned/generated ID types,
strict mapping failure, and different entity classes sharing equal ID values.

## Task 4: Implement The Operation Queue

**Files**

- Create: `src/opal/data/operation_queue.cr`
- Create: `spec/data/entity_manager_queue_spec.cr`

The queue preserves first scheduling order. It stores object references and
operation kind, not snapshots of property values. SQL arguments are read from
the entity at flush time.

Rules:

- INSERT followed by repeated persist remains one INSERT;
- INSERT followed by remove disappears from the queue;
- UPDATE followed by repeated persist remains one UPDATE;
- UPDATE followed by remove becomes DELETE in its existing queue position;
- a successful operation is removed from the queue;
- operations scheduled after a successful explicit flush form a new batch.

## Task 5: Execute INSERT

**Files**

- Create: `spec/data/entity_manager_insert_spec.cr`

Test assigned ID, generated Int64 ID, generated Int32 overflow, nilable fields,
converters, uniqueness failure, and listener event. Use
`DB::ExecResult#last_insert_id` through the dialect.

Apply generated ID only after the statement succeeds. Register database
identity only after a valid ID exists. A duplicate assigned ID failure remains
the original driver error and marks the manager failed.

## Task 6: Execute UPDATE And DELETE

**Files**

- Create: `spec/data/entity_manager_update_spec.cr`
- Create: `spec/data/entity_manager_delete_spec.cr`

UPDATE writes every writable field using current values at flush. DELETE uses
the managed ID. Before optimistic locking, zero affected rows for UPDATE/DELETE
raises `EntityStateError` because a managed row disappeared.

After successful DELETE, remove the database identity entry and mark the object
Detached. It cannot be persisted again in the same manager.

## Task 7: Define Flush Failure Semantics

**Files**

- Create: `spec/data/entity_manager_flush_spec.cr`

Test:

- no-op flush performs no statement;
- statements execute in queue order;
- explicit flush can be called repeatedly;
- failure on operation N stops before N+1;
- original DB/converter/listener-independent error propagates;
- manager becomes failed;
- all subsequent find/query/persist/remove/flush calls raise
  `FailedEntityManagerError`;
- close remains idempotent after failure.

The database transaction rollback is owned by DataSource, not EntityManager.

## Task 8: Replace The Temporary DataSource Seam

**Files**

- Modify: `src/opal/data/data_source.cr`
- Delete: temporary no-op manager implementation from Plan 03
- Modify: `spec/data/data_source_spec.cr`

DataSource creates the real manager with transaction connection, dialect, and
listener dispatcher. Normal block return invokes `flush` before `crystal-db`
commits. Exception skips automatic flush. Manager closes in `ensure`.

Regression specs prove:

- query-only transaction emits no write;
- generated ID is visible after automatic flush only after block body ends, so
  mid-block use still requires explicit `flush`;
- block error and flush error both rollback;
- escaped manager references reject use after block completion.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/data/entity_manager_state_spec.cr \
  spec/data/entity_manager_find_spec.cr \
  spec/data/entity_manager_queue_spec.cr \
  spec/data/entity_manager_insert_spec.cr \
  spec/data/entity_manager_update_spec.cr \
  spec/data/entity_manager_delete_spec.cr \
  spec/data/entity_manager_flush_spec.cr \
  spec/data/data_source_spec.cr --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Commit by green capability:

```text
feat(data): add entity identity and state tracking
feat(data): add explicit unit of work flush
```
