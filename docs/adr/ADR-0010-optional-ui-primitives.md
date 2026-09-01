# ADR-0010: Optional Stateless UI Primitives

- Status: Accepted
- Date: 2026-09-01
- Deciders: Opal maintainers
- Extends: ADR-0007
- Related: `LF::UI`, `LF::LiveView::Rendered`, Tailwind CSS

## Context

LiveView applications need a usable baseline for actions, feedback, forms, and
data presentation. Repeating HTML and accessibility wiring in every project
makes examples noisy and encourages inconsistent form errors, focus states,
and event attributes. Making every visual primitive a stateful LiveView
component would also create unnecessary connection-owned identities and
lifecycle work.

The styling layer must remain optional. Requiring Opal's HTTP, Data, or
LiveView packages must not impose a Node runtime, browser dependency, global
CSS reset, or application theme.

## Decision

Opal provides `LF::UI` behind the explicit `require "opal/ui"` entrypoint.
Primitives are module functions that return structural
`LF::LiveView::Rendered` values. They accept normal escaped text, nested
`Rendered` values, or explicitly trusted `HTML::Safe` markup. They do not own
connection state.

Variants use the `Tone`, `Size`, and `ButtonVariant` enums. Component-owned
HTML attributes have typed arguments. Extension attributes are limited to safe
global names and `data-*` / `aria-*`; inline event handlers and unknown URL
schemes are rejected.

The initial component families are:

- button and link button;
- badge and alert;
- card and card sections;
- field, input, textarea, select, checkbox, radio, and switch;
- composable table elements.

Opal ships a minified stylesheet generated with Tailwind CSS. The source scans
complete class literals in `src/opal/ui`, does not include Tailwind Preflight,
and can be regenerated with `npm run build:ui-css`. Applications may embed the
compiled theme, mount it as a cacheable HTTP asset, or run their own Tailwind
build against the library source.

Component state remains application-owned. Interactive overlay components may
later use the existing LiveView hook contract for focus management, keyboard
behavior, and local presentation. A stateful LiveView component is reserved for
behavior that genuinely requires server-owned state.

## Consequences

- Applications can adopt standard markup and accessibility without changing
  their rendering or connection ownership model.
- Core Opal users pay no compile-time or CSS cost unless they require the UI
  entrypoint.
- Production use does not require Node because generated CSS is committed and
  embedded at Crystal compile time.
- Contributors need Node only when UI class literals or theme sources change.
- The precompiled theme is intentionally a baseline. Applications that require
  design-token or utility-level customization should own the Tailwind build.
- Complex interactive components remain a separate slice with browser-level
  accessibility tests.
