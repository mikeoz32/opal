require "./live_view"
require "./ui/types"
require "./ui/support"
require "./ui/theme"
require "./ui/actions"
require "./ui/feedback"
require "./ui/layout"
require "./ui/forms"
require "./ui/table"
require "./ui/dialog"
require "./ui/dropdown"
require "./ui/tabs"
require "./ui/toast"
require "./ui/accordion"
require "./ui/tooltip"
require "./ui/pagination"
require "./ui/data_table"

# Optional stateless HTML primitives for normal server rendering and LiveView.
#
# Load with `require "opal/ui"`. Components return structural
# `LF::LiveView::Rendered` values and use the precompiled Tailwind theme made
# available by `LF::UI.stylesheet_tag` or `LF::UI.mount_assets`.
module LF::UI
end
