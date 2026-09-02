require "spec"
require "../src/ui_showcase"

describe UIShowcaseLive do
  it "renders every primitive family and handles live state" do
    view = UIShowcaseLive.new
    request = HTTP::Request.new("GET", "/")
    view.__opal_mount(LF::LiveView::MountContext.new(request, {} of String => String, request.resource, true))

    initial = view.__opal_render.to_html
    initial.should contain(%(data-opal-ui="button"))
    initial.should contain(%(data-opal-ui="alert"))
    initial.should contain(%(data-opal-ui="input"))
    initial.should contain(%(data-opal-ui="select"))
    initial.should contain(%(data-opal-ui="switch"))
    initial.should contain(%(data-opal-ui="table"))
    initial.should contain(%(data-opal-ui="dialog"))
    initial.should contain(%(data-opal-dialog-open="false"))
    initial.should contain(%(data-opal-ui="dropdown"))
    initial.should contain(%(data-opal-ui="tabs"))
    initial.should contain(%(data-opal-ui="toast-region"))
    initial.should_not contain(%(data-opal-ui="toast"))

    view.__opal_handle_event(nil, "toggle_notifications", JSON.parse("{}"))
    view.__opal_handle_event(nil, "toggle_deployment", JSON.parse("{}"))
    view.__opal_handle_event(nil, "save_profile", JSON.parse(%({"name":"Mike","role":"admin"})))

    updated = view.__opal_render.to_html
    updated.should contain(%(id="notifications-switch"))
    updated.should contain(%(aria-checked="false"))
    updated.should contain("Ready to deploy")
    updated.should contain(%(id="saved-status"))

    view.__opal_handle_event(nil, "open_release_dialog", JSON.parse("{}"))
    opened = view.__opal_render.to_html
    opened.should contain(%(data-opal-dialog-open="true"))
    opened.should contain("Dialog update 0")

    view.__opal_handle_event(nil, "refresh_release_dialog", JSON.parse("{}"))
    refreshed = view.__opal_render.to_html
    refreshed.should contain("Dialog update 1")

    view.__opal_handle_event(nil, "close_release_dialog", JSON.parse(%({"reason":"escape"})))
    closed = view.__opal_render.to_html
    closed.should contain(%(data-opal-dialog-open="false"))
    closed.should contain("Closed by escape")

    view.__opal_handle_event(nil, "run_menu_action", JSON.parse(%({"item":"checks"})))
    menu_updated = view.__opal_render.to_html
    menu_updated.should contain("Selected checks")

    view.__opal_handle_event(nil, "select_component_tab", JSON.parse(%({"tab":"activity"})))
    tabs_updated = view.__opal_render.to_html
    tabs_updated.should contain(%(id="activity-tab"))
    tabs_updated.should contain(%(aria-selected="true"))
    tabs_updated.should contain("Recent builds and deployment events.")

    view.__opal_handle_event(nil, "show_release_toast", JSON.parse("{}"))
    toast_visible = view.__opal_render.to_html
    toast_visible.should contain(%(data-opal-ui="toast"))
    toast_visible.should contain("Release ready")

    view.__opal_handle_event(nil, "dismiss_release_toast", JSON.parse(%({"reason":"button"})))
    toast_dismissed = view.__opal_render.to_html
    toast_dismissed.should_not contain(%(data-opal-ui="toast"))
    toast_dismissed.should contain("Toast dismissed by button")
  ensure
    view.try(&.__opal_disconnect)
  end

  it "renders accessible validation errors" do
    view = UIShowcaseLive.new
    request = HTTP::Request.new("GET", "/")
    view.__opal_mount(LF::LiveView::MountContext.new(request, {} of String => String, request.resource, true))
    view.__opal_handle_event(nil, "validate_profile", JSON.parse(%({"name":"","role":""})))

    rendered = view.__opal_render.to_html
    rendered.should contain("Name is required")
    rendered.should contain("Choose a role")
    rendered.should contain(%(aria-describedby="profile-name-hint profile-name-error"))
    rendered.should contain(%(aria-invalid="true"))
  ensure
    view.try(&.__opal_disconnect)
  end
end
