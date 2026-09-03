require "opal"
require "opal/autoconfig/http"

@[LF::DI::Service]
class CounterLabel
  def heading : String
    "Opal LiveView counter"
  end
end

class PlainPageController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/plain")]
  def show : String
    "Plain non-LiveView page"
  end
end

class NestedGrandchildLive < LF::LiveView::View
  @count = 0
  @label = "Grandchild"

  def mount(context : LF::LiveView::MountContext) : Nil
    @label = context.session.as_h["label"].as_s
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    if event == "increment_nested_grandchild"
      @count += 1
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(<<-HTML)
      <section>
        <h3>#{@label} LiveView</h3>
        <button type="button" phx-click="increment_nested_grandchild">Increment nested grandchild LiveView</button>
        <output id="nested-grandchild-value">#{@count}</output>
      </section>
    HTML
  end
end

class NestedChildLive < LF::LiveView::View
  @count = 0
  @label = "Child"

  def mount(context : LF::LiveView::MountContext) : Nil
    @label = context.session.as_h["label"].as_s
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment_nested_child"
      @count += 1
    when "crash_nested_child"
      raise "nested child failure"
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    grandchild = live_view(
      NestedGrandchildLive,
      "nested-grandchild-live",
      {label: "Grandchild"}
    ) { NestedGrandchildLive.new }
    LF::LiveView::HTML.rendered(<<-HTML)
      <section>
        <h2>#{@label} LiveView</h2>
        <button type="button" phx-click="increment_nested_child">Increment nested child LiveView</button>
        <button type="button" phx-click="crash_nested_child">Crash nested child LiveView</button>
        <output id="nested-child-value">#{@count}</output>
        #{grandchild}
      </section>
    HTML
  end
end

@[LF::LiveView::Page("/nested")]
class NestedLivePage < LF::LiveView::View
  @count = 0
  @show_child = true

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment_nested_parent"
      @count += 1
    when "toggle_nested_child"
      @show_child = !@show_child
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    child = if @show_child
              live_view(NestedChildLive, "nested-child-live", {label: "Child"}) do
                NestedChildLive.new
              end
            else
              ""
            end
    LF::LiveView::HTML.rendered(<<-HTML)
      <main>
        <h1>Nested LiveViews</h1>
        <button type="button" phx-click="increment_nested_parent">Increment nested parent LiveView</button>
        <output id="nested-parent-value">#{@count}</output>
        <button type="button" phx-click="toggle_nested_child">Toggle nested child LiveView</button>
        #{child}
      </main>
    HTML
  end
end

class CounterDetailComponent < LF::LiveView::Component
  @count = 0
  @owner_id = "counter"
  @owner_label = "Counter"
  @parent_count = 0

  def update(assigns : JSON::Any) : Nil
    values = assigns.as_h
    @owner_id = values["owner_id"].as_s
    @owner_label = values["owner_label"].as_s
    @parent_count = values["parent_count"].as_i.to_i
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    if event == "increment_nested_component"
      @count += 1
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(<<-HTML)
      <section id="#{@owner_id}-nested-component">
        <h3>#{@owner_label} nested component</h3>
        <p>Parent count: <output id="#{@owner_id}-nested-parent-value">#{@parent_count}</output></p>
        <button type="button" phx-click="increment_nested_component" phx-target="#{myself}" aria-label="Increment #{@owner_label} nested component">Nested +</button>
        <output id="#{@owner_id}-nested-component-value" aria-live="polite">#{@count}</output>
      </section>
    HTML
  end
end

class CounterComponent < LF::LiveView::Component
  @count = 0
  @label = "Counter"
  @show_nested = true

  def update(assigns : JSON::Any) : Nil
    @label = assigns.as_h["label"].as_s
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment_component"
      @count += 1
    when "decrement_component"
      @count -= 1
    when "hook_component"
      push_event("component_notice", {id: id, count: @count})
      reply({id: id, count: @count})
    when "toggle_nested_component"
      @show_nested = !@show_nested
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    nested = if @show_nested
               live_component(
                 CounterDetailComponent,
                 "details",
                 {owner_id: id, owner_label: @label, parent_count: @count}
               ) do
                 CounterDetailComponent.new
               end
             else
               LF::LiveView::Rendered.opaque("")
             end

    LF::LiveView::HTML.rendered(<<-HTML)
      <section id="component-#{id}">
        <h2>#{@label} component</h2>
        <div class="counter">
          <button type="button" phx-click="decrement_component" phx-target="#{myself}" aria-label="Decrement #{@label} component">−</button>
          <output id="#{id}-component-value" aria-live="polite">#{@count}</output>
          <button type="button" phx-click="increment_component" phx-target="#{myself}" aria-label="Increment #{@label} component">+</button>
        </div>
        <button type="button" phx-click="toggle_nested_component" phx-target="#{myself}">Toggle #{@label} nested component</button>
        #{nested}
      </section>
    HTML
  end
end

@[LF::LiveView::Page("/")]
class CounterLive < LF::LiveView::View
  @count = 0
  @name = "friend"
  @draft_name = "friend"
  @validation_count = 0
  @empty_title = false
  @items_reversed = false
  @next_activity = 3
  @page = 1
  @hook_message = "waiting"
  @show_hook = true

  def initialize(@counter_label : CounterLabel)
  end

  def mount(context : LF::LiveView::MountContext) : Nil
    if start = context.query_params["start"]?
      @count = start.to_i? || 0
    end
    stream_reset("activity-stream")
    stream_insert("activity-stream", "activity-1", activity_item(1))
    stream_insert("activity-stream", "activity-2", activity_item(2))
  end

  def handle_params(context : LF::LiveView::ParamsContext) : Nil
    @page = context.query_params["page"]?.try(&.to_i?) || 1
    @page = 1 if @page < 1
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment"
      @count += 1
    when "decrement"
      @count -= 1
    when "increment_later"
      spawn do
        sleep 250.milliseconds
        send_info("increment")
      end
    when "validate_name"
      @draft_name = string_value(value, "name")
      @validation_count += 1
    when "save_name"
      @draft_name = string_value(value, "name")
      @name = @draft_name unless @draft_name.blank?
    when "clear_title"
      @empty_title = true
    when "reverse_items"
      @items_reversed = !@items_reversed
    when "prepend_activity"
      sequence = @next_activity
      @next_activity += 1
      stream_insert(
        "activity-stream",
        "activity-#{sequence}",
        activity_item(sequence),
        at: 0,
        limit: 3
      )
    when "delete_activity"
      item_id = string_value(value, "id")
      stream_delete("activity-stream", item_id) unless item_id.empty?
    when "next_page"
      push_patch("/?start=#{@count}&page=#{@page + 1}")
    when "replace_page"
      push_patch("/?start=#{@count}&page=#{@page + 1}", replace: true)
    when "hook_ping"
      @hook_message = string_value(value, "message")
      push_event("counter_notice", {message: @hook_message, count: @count})
      reply({accepted: true, message: @hook_message, count: @count})
    when "push_hook_notice"
      push_event("counter_notice", {message: "server push", count: @count})
    when "toggle_hook"
      @show_hook = !@show_hook
    else
      super
    end
  end

  def handle_info(name : String, value : JSON::Any) : Nil
    case name
    when "increment"
      @count += 1
    else
      super
    end
  end

  def render : LF::LiveView::Rendered
    left_component = live_component(CounterComponent, "left", {label: "Left"}) do
      CounterComponent.new
    end
    right_component = live_component(CounterComponent, "right", {label: "Right"}) do
      CounterComponent.new
    end
    activity_items = stream_contents("activity-stream")
    hook = if @show_hook
             LF::LiveView::HTML.rendered(<<-HTML)
               <section id="counter-hook" phx-hook="CounterHook" data-message="#{@hook_message}">
                 <h2>JavaScript hook</h2>
                 <button id="hook-ping" type="button">Ping view from hook</button>
                 <button id="hook-component-ping" type="button">Ping left component from hook</button>
                 <output id="hook-server-state">#{@hook_message}</output>
                 <output id="hook-client-notice">No notice</output>
               </section>
             HTML
           else
             LF::LiveView::Rendered.opaque("")
           end
    previous_page = {@page - 1, 1}.max
    previous_page_path = "/?start=#{@count}&page=#{previous_page}"
    next_page_path = "/?start=#{@count}&page=#{@page + 1}"
    items = [
      {"first", "First keyed item"},
      {"second", "Second keyed item"},
      {"third", "Third keyed item"},
    ]
    items.reverse! if @items_reversed
    keyed_items = LF::LiveView::HTML.keyed(items) do |item|
      id, label = item
      {id, LF::LiveView::HTML.rendered(%(<li id="item-#{id}">#{label}</li>))}
    end

    LF::LiveView::HTML.rendered(<<-HTML)
      <style>
        :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
        #opal-live-root { max-width: 34rem; margin: 5rem auto; padding: 2rem; }
        .counter { display: flex; align-items: center; gap: 1rem; margin: 2rem 0; }
        button, input { font: inherit; padding: .65rem 1rem; }
        output { min-width: 4ch; text-align: center; font-size: 2rem; }
        .components { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 1rem; }
        .components section { border: 1px solid currentColor; border-radius: .5rem; padding: 0 1rem; }
        #activity-stream { padding: 0; list-style: none; }
        #activity-stream li { display: flex; justify-content: space-between; align-items: center; margin: .5rem 0; }
        #opal-live-root.phx-loading::before { content: "Reconnecting..."; color: #d97706; }
      </style>
      <h1>#{@counter_label.heading}</h1>
      <p>Hello, <strong>#{@name}</strong>.</p>
      <nav aria-label="Live navigation">
        <a id="previous-page" href="#{previous_page_path}" data-phx-link="patch" data-phx-link-state="replace">Previous page</a>
        <a id="next-page" href="#{next_page_path}" data-phx-link="patch" data-phx-link-state="push">Next page</a>
        <button type="button" phx-click="next_page">Next page from server</button>
        <button type="button" phx-click="replace_page">Replace page from server</button>
        <a href="/about">About this example</a>
        <a href="/plain">Plain page</a>
      </nav>
      <output id="page-value" data-testid="page-value">#{@page}</output>
      <div class="counter">
        <button type="button" phx-click="decrement" aria-label="Decrement">−</button>
        <output id="counter-value" aria-live="polite">#{@count}</output>
        <button type="button" phx-click="increment" aria-label="Increment">+</button>
        <button type="button" phx-click="increment_later">+1 later</button>
        <button type="button" phx-click="clear_title">Clear title</button>
      </div>
      <form phx-change="validate_name" phx-debounce="150" phx-submit="save_name">
        <label>
          Name
          <input id="name" name="name" value="#{@draft_name}" autocomplete="off">
        </label>
        <button type="submit">Save</button>
      </form>
      <output id="validation-count" data-testid="validation-count">#{@validation_count}</output>
      <div class="components">#{left_component}#{right_component}</div>
      <section>
        <button type="button" phx-click="push_hook_notice">Push notice to hook</button>
        <button type="button" phx-click="toggle_hook">Toggle hook</button>
        #{hook}
      </section>
      <section>
        <h2>Activity stream</h2>
        <button type="button" phx-click="prepend_activity">Prepend activity</button>
        <ul id="activity-stream" phx-update="stream">#{activity_items}</ul>
      </section>
      <button type="button" phx-click="reverse_items">Reverse keyed items</button>
      <ul id="keyed-items">#{keyed_items}</ul>
    HTML
  end

  def title : String?
    @empty_title ? "" : "Counter #{@count} · Opal"
  end

  def render_document(live_root : String, client_script : String) : String
    <<-HTML
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <link rel="icon" href="data:,">
          <title data-default="">#{LF::LiveView::HTML.escape(title || "Opal LiveView")}</title>
        </head>
        <body>
          #{live_root}
          <script>
            globalThis.__opalHookLog = [];
            globalThis.__opalHookReplies = [];
            globalThis.__opalHookNotices = [];
            globalThis.OpalLiveViewHooks = {
              CounterHook: {
                mounted() {
                  globalThis.__opalHookLog.push("mounted");
                  this.el.dataset.clientState = "preserved";
                  this.noticeRef = this.handleEvent("counter_notice", payload => {
                    globalThis.__opalHookLog.push("notice");
                    globalThis.__opalHookNotices.push(payload);
                    this.el.querySelector("#hook-client-notice").textContent = payload.message;
                  });
                  this.componentNoticeRef = this.handleEvent("component_notice", payload => {
                    globalThis.__opalHookLog.push("component-notice");
                    globalThis.__opalHookNotices.push(payload);
                  });
                  this.onPing = async () => {
                    const reply = await this.pushEvent("hook_ping", {message: "hello from hook"});
                    globalThis.__opalHookLog.push("reply");
                    globalThis.__opalHookReplies.push(reply);
                  };
                  this.onComponentPing = async () => {
                    const results = await this.pushEventTo("#component-left", "hook_component");
                    globalThis.__opalHookLog.push("component-reply");
                    globalThis.__opalHookReplies.push(results[0].value);
                  };
                  this.el.querySelector("#hook-ping").addEventListener("click", this.onPing);
                  this.el.querySelector("#hook-component-ping").addEventListener("click", this.onComponentPing);
                },
                beforeUpdate(toEl) {
                  globalThis.__opalHookLog.push("beforeUpdate");
                  toEl.dataset.clientState = this.el.dataset.clientState;
                },
                updated() {
                  globalThis.__opalHookLog.push("updated");
                },
                destroyed() {
                  globalThis.__opalHookLog.push("destroyed");
                  this.removeHandleEvent(this.noticeRef);
                  this.removeHandleEvent(this.componentNoticeRef);
                  this.el.querySelector("#hook-ping")?.removeEventListener("click", this.onPing);
                  this.el.querySelector("#hook-component-ping")?.removeEventListener("click", this.onComponentPing);
                },
                disconnected() {
                  globalThis.__opalHookLog.push("disconnected");
                },
                reconnected() {
                  globalThis.__opalHookLog.push("reconnected");
                }
              }
            };
          </script>
          #{client_script}
        </body>
      </html>
    HTML
  end

  private def string_value(value : JSON::Any, key : String) : String
    value.as_h[key]?.try(&.as_s) || ""
  rescue TypeCastError
    ""
  end

  private def activity_item(sequence : Int32) : LF::LiveView::Rendered
    id = "activity-#{sequence}"
    LF::LiveView::HTML.rendered(<<-HTML)
      <li id="#{id}">
        <span>Activity #{sequence}</span>
        <button type="button" phx-click="delete_activity" phx-value-id="#{id}" aria-label="Remove Activity #{sequence}">Remove</button>
      </li>
    HTML
  end
end

@[LF::LiveView::Page("/about")]
class AboutLive < LF::LiveView::View
  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(<<-HTML)
      <h1>About Opal LiveView</h1>
      <p>This page was mounted through a fresh document navigation.</p>
      <a href="/">Back to counter</a>
    HTML
  end

  def title : String?
    "About · Opal LiveView"
  end
end

@[LF::Application]
@[LF::AutoConfig::HTTP]
class LiveViewCounterApplication
end
