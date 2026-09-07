require "./live_view/endpoint"

# Server-rendered, event-driven pages over Opal's native WebSocket transport.
#
# LiveView is loaded by the core `opal` entry point. Its browser runtime uses
# the pinned upstream Phoenix and Phoenix LiveView packages bundled with Opal,
# while page classes, lifecycle callbacks, and rendering remain Crystal code.
# See `LF::LiveView::View` and `LF::LiveView::Page` for the page contract.
module LF::LiveView
end
