# Opal UI

`LF::UI` is an optional set of stateless, accessible HTML primitives for Opal
LiveView and normal server rendering. It emits structural
`LF::LiveView::Rendered` values and ships a precompiled Tailwind CSS theme.

```crystal
require "opal"
require "opal/ui"
```

Requiring `opal` alone does not load the UI layer.

## Theme

The shortest setup embeds the 23 KB minified theme in an application document:

```crystal
def render_document(live_root : String, client_script : String) : String
  <<-HTML
    <!doctype html>
    <html>
      <head>#{LF::UI.stylesheet_tag.value}</head>
      <body>#{live_root}#{client_script}</body>
    </html>
  HTML
end
```

Pass `nonce:` when the Content Security Policy allows nonce-bearing inline
styles. For a cacheable response, mount the asset on an application-owned
router and link it:

```crystal
app = LF::HTTP::App.new do |router|
  LF::UI.mount_assets(router)
  # Mount controllers or LiveView routes here.
end

LF::UI.stylesheet_link # /_opal/ui.css
```

Applications with their own Tailwind build may omit the precompiled theme and
scan Opal's complete literal utility classes instead. With Tailwind 4, add the
library source to the application stylesheet:

```css
@import "tailwindcss";
@source "../lib/opal/src/opal/ui";
```

Never construct Tailwind class names from partial user values. Component
variants use enums and map to complete class literals so Tailwind can detect
them statically.

## Actions and feedback

```crystal
LF::UI.button(
  "Save",
  type: "submit",
  tone: LF::UI::Tone::Primary,
  size: LF::UI::Size::Medium,
  attributes: {"data-opal-click" => "save"}
)

LF::UI.link_button(
  "Documentation",
  "/docs",
  variant: LF::UI::ButtonVariant::Outline
)

LF::UI.badge("Ready", tone: LF::UI::Tone::Success)

LF::UI.alert(
  "All checks passed.",
  title: "Ready to deploy",
  tone: LF::UI::Tone::Success,
  live: true
)
```

`link_button` accepts relative URLs plus `http`, `https`, `mailto`, and `tel`.
It rejects executable or unknown URL schemes. A disabled link omits `href` and
receives `aria-disabled="true"` and `tabindex="-1"`.

## Cards

Card parts are independently composable:

```crystal
header = LF::UI.card_header(
  LF::LiveView::HTML.raw(
    LF::UI.card_title("Account").to_html +
    LF::UI.card_description("Workspace profile and preferences.").to_html
  )
)
body = LF::UI.card_body("Content")
footer = LF::UI.card_footer(LF::UI.button("Save"))

LF::UI.card(
  LF::LiveView::HTML.raw(header.to_html + body.to_html + footer.to_html)
)
```

`HTML.raw` is appropriate above because every fragment came from a framework
component. Do not wrap user-controlled HTML with it.

## Forms

Text controls render their label, required marker, hint, error, and ARIA
relationships together:

```crystal
LF::UI.input(
  "Email",
  id: "email",
  name: "email",
  value: @email,
  type: "email",
  autocomplete: "email",
  hint: "Use your work address.",
  error: @email_error,
  required: true,
  attributes: {"data-opal-change" => "validate_email"}
)
```

Available controls are:

- `input`
- `textarea`
- `select` with typed `LF::UI::SelectOption` values
- `checkbox`
- `radio`
- `switch`
- `field` for wrapping an application-owned custom control

For `field`, the custom control is responsible for referencing `<id>-hint` and
`<id>-error` through `aria-describedby`. The built-in controls do this
automatically.

The switch is a button with `role="switch"`; update its `checked` argument from
a LiveView event. It deliberately does not hide a form input or create client-
owned state.

## Tables

Tables use composable `table`, `table_head`, `table_body`, `table_row`,
`table_header`, and `table_cell` helpers. `table` renders its caption as
screen-reader-only content, and `table_header` requires a valid HTML scope.

## Custom attributes

Every component accepts `class_name` and a string attribute map. Typed
arguments own structural attributes such as `type`, `href`, `disabled`, `id`,
and `name`. The extension map accepts safe global attributes plus `data-*` and
`aria-*`; it rejects inline event handlers and arbitrary attributes.

Normal text is HTML escaped. Pass `LF::LiveView::Rendered` or an explicit
`LF::LiveView::HTML::Safe` value only for trusted nested markup.

## Stateful behavior

UI primitives are not `LF::LiveView::Component` subclasses. Buttons, fields,
cards, badges, and tables do not own connection state and therefore should not
consume component identities. Application views own state and pass the current
values when rendering. Future modal, dropdown, tabs, toast, and accordion
components may use dependency-free browser hooks for local interaction; server
state remains explicit when the application needs it.

See [the UI showcase](../examples/ui_showcase/README.md) for a runnable page
covering every primitive family and LiveView validation updates.
