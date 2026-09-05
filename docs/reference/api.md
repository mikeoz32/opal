# Crystal API reference

The API reference is generated directly from inline Crystal docstrings in
`src/` during every documentation build. It is intentionally not hand-written:
the signatures, source locations, and type hierarchy always correspond to the
checked-out source tree.

<div class="grid cards" markdown>

-   :material-code-braces: **Open generated API reference**

    <a class="md-button md-button--primary" href="../../api/index.html">Browse the Crystal API</a>

</div>

## Build it locally

Create a dedicated documentation environment once:

```bash
python3 -m venv .venv-docs
.venv-docs/bin/python -m pip install -r requirements-docs.txt
```

Then build the guides and the Crystal API together:

```bash
PATH="$PWD/.venv-docs/bin:$PATH" scripts/build_docs.sh
```

The output is `build/docs/site/`; the generated API is under
`build/docs/site/api/`. The source link ref defaults to `main`; use
`OPAL_DOCS_REF=<branch-or-tag>` to override the checked-out Git ref.

!!! note "Why two generators?"

    Material for MkDocs is optimized for tutorials, guides, navigation, and
    search. `crystal docs` understands Crystal declarations and creates the
    canonical symbol-level reference. The site build packages both into one
    static artifact.
