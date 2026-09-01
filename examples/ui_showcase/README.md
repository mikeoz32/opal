# Opal UI Showcase

This runnable LiveView demonstrates the optional `LF::UI` primitives and the
precompiled Tailwind theme. It covers actions, feedback, cards, accessible form
controls, validation, switches, and composable tables.

From this directory:

```bash
shards install
crystal spec --no-color
crystal run src/ui_showcase_example.cr
```

Open <http://127.0.0.1:8085/>.

The example embeds `LF::UI.stylesheet_tag` in its document for a zero-setup
quick start. Production applications may instead call `LF::UI.mount_assets`
while constructing their router and use `LF::UI.stylesheet_link` for a
cacheable CSS response.
