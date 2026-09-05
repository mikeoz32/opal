# Contributing documentation

Documentation is a product surface. A change to a public behavior should
update the closest guide and, when it adds or changes a public declaration,
the inline Crystal docstring that feeds the API reference.

## Write in the right place

| Content | Location |
| --- | --- |
| Getting a user from zero to a running result | `docs/tutorials/` |
| Explaining a reusable concept or integration | `docs/guides/` or an existing feature guide |
| Stable option, lifecycle, or capability matrix | `docs/reference/` |
| Public class, module, annotation, or method contract | comment immediately before the Crystal declaration in `src/` |
| Architectural decision and trade-offs | `docs/adr/` |
| Historical implementation planning | `docs/plans/` (not in primary site navigation) |

## Keep examples trustworthy

- Prefer a small complete snippet over a partial API inventory.
- State imports and ownership boundaries explicitly.
- Link to a repository example when the tutorial needs more than one source
  file.
- Do not claim a feature exists just because a similar framework has it.
- Call out deliberate non-goals, especially lazy loading, hidden persistence,
  and browser OAuth redirect handling.

## Preview before review

```bash
python3 -m venv .venv-docs
.venv-docs/bin/python -m pip install -r requirements-docs.txt
PATH="$PWD/.venv-docs/bin:$PATH" scripts/serve_docs.sh
```

Open `http://127.0.0.1:8000`. The generated artifact is intentionally ignored;
only Markdown, configuration, source docstrings, and build scripts are
committed.

## Verify a documentation change

```bash
PATH="$PWD/.venv-docs/bin:$PATH" scripts/check_docs.sh
```

The check builds Material for MkDocs and `crystal docs`, then asserts that both
the guide landing page and generated API index exist. The repository also has
a manual GitHub Actions workflow for the same check while automatic CI remains
intentionally disabled.
