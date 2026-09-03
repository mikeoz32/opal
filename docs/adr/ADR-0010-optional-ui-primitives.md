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
HTML attributes have typed arguments. Extension attributes are limited to
upstream `phx-*` bindings, safe global names, and `data-*` / `aria-*`; legacy
LiveView binding names, inline event handlers, and unknown URL schemes are
rejected.

The initial component families are:

- button and link button;
- badge and alert;
- card and card sections;
- field, input, textarea, select, checkbox, radio, and switch;
- composable table elements;
- native modal dialog;
- dropdown menu, tabs, toast, and toast region;
- accordion, tooltip, and pagination;
- typed server-driven data tables composed over table and pagination
  primitives.

Opal ships a minified stylesheet generated with Tailwind CSS. The source scans
complete class literals in `src/opal/ui`, does not include Tailwind Preflight,
and can be regenerated with `npm run build:ui-css`. Applications may embed the
compiled theme, mount it as a cacheable HTTP asset, or run their own Tailwind
build against the library source.

Interactive primitives use a separate dependency-free browser-hook asset.
Applications opt into that asset inline or through the cacheable UI route and
load it before the LiveView client. The native dialog primitive uses the hook
only to synchronize top-layer, close-request, and focus behavior; its open
state remains application-owned. Dropdown and tooltip visibility are local
ephemeral state; accordion expansion, tab selection, pagination parameters,
toast presence, data-table ordering, row selection, and failure/loading state
remain application-owned. Their hooks provide keyboard
focus, DOM-morph continuity, and optional dismissal timers. Pagination uses
the upstream `data-phx-link` live-patch contract and does not need a hook.

Data tables accept application-loaded rows, typed column renderers, stable row
keys, optional paging metadata, and already-rendered pagination. They never
open transactions or execute queries. This keeps `opal/ui` independent from
the optional Data package and lets the same component consume repository
pages, API responses, or in-memory collections. Rows use native Phoenix keyed
comprehensions; sorting and selection use normal `phx-*` events and remain
server-owned. No DataTable-specific browser hook is required.

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
- The bundled theme removes component transition and animation durations for
  users who request reduced motion.
- The precompiled theme is intentionally a baseline. Applications that require
  design-token or utility-level customization should own the Tailwind build.
- Interactive components require browser-level keyboard, focus, reconnect, and
  DOM-morph tests.
- DataTable callers must validate sort keys and selection identifiers before
  applying them to application state or typed queries.
