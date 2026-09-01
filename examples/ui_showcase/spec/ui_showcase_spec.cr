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

    view.__opal_handle_event(nil, "toggle_notifications", JSON.parse("{}"))
    view.__opal_handle_event(nil, "toggle_deployment", JSON.parse("{}"))
    view.__opal_handle_event(nil, "save_profile", JSON.parse(%({"name":"Mike","role":"admin"})))

    updated = view.__opal_render.to_html
    updated.should contain(%(id="notifications-switch"))
    updated.should contain(%(aria-checked="false"))
    updated.should contain("Ready to deploy")
    updated.should contain(%(id="saved-status"))
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
