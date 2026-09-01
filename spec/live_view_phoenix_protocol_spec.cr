require "./support/live_view_protocol_support"

private def live_session(body : String) : String
  body.match(/data-phx-session="([^"]+)"/).not_nil![1]
end

private def phoenix_socket(address : Socket::IPAddress, headers = HTTP::Headers.new) : HTTP::WebSocket
  HTTP::WebSocket.new(
    "127.0.0.1",
    "/_opal/live/websocket?vsn=2.0.0",
    port: address.port,
    headers: headers
  )
end

private def phoenix_send(
  websocket : HTTP::WebSocket,
  join_ref : String?,
  reference : String?,
  topic : String,
  event : String,
  payload,
) : Nil
  websocket.send(JSON.build do |json|
    json.array do
      join_ref ? json.string(join_ref) : json.null
      reference ? json.string(reference) : json.null
      json.string(topic)
      json.string(event)
      payload.to_json(json)
    end
  end)
end

private def phoenix_receive(websocket : HTTP::WebSocket) : Array(JSON::Any)
  JSON.parse(websocket.receive.as(String)).as_a
end

private def phoenix_join(
  websocket : HTTP::WebSocket,
  token : String,
  url : String,
  *,
  join_ref = "1",
  reference = "1",
  topic = "lv:opal-live-root",
) : Array(JSON::Any)
  phoenix_send(
    websocket,
    join_ref,
    reference,
    topic,
    "phx_join",
    {
      url:     url,
      params:  {"_mounts" => 0},
      session: token,
      static:  nil,
    }
  )
  phoenix_receive(websocket)
end

private def phoenix_response(envelope : Array(JSON::Any)) : Hash(String, JSON::Any)
  envelope[3].as_s.should eq("phx_reply")
  payload = envelope[4].as_h
  payload["status"].as_s.should eq("ok")
  payload["response"].as_h
end

describe "Phoenix LiveView protocol compatibility" do
  it "keeps structural rendering, escaping, and signed mount state" do
    unsafe = %(<Mike & "Opal">)
    initial = LF::LiveView::HTML.rendered(%(<p>#{unsafe}: #{1}</p>))
    updated = LF::LiveView::HTML.rendered(%(<p>#{unsafe}: #{2}</p>))

    initial.to_html.should eq("<p>&lt;Mike &amp; &quot;Opal&quot;&gt;: 1</p>")
    updated.diff(initial).should eq({1 => "2"})

    tokens = LF::LiveView::MountToken.new("s" * 32, 1.hour)
    token = tokens.sign("Counter", {"id" => "7"}, "/counter?id=7")
    tokens.verify(token).resource.should eq("/counter?id=7")
    expect_raises(LF::LiveView::InvalidMountTokenError) do
      tokens.verify(token.sub('C', 'X'))
    end

    now = Time.utc
    short_lived = LF::LiveView::MountToken.new("m" * 32, 500.milliseconds)
    expiring = short_lived.sign("Counter", {} of String => String, "/counter", now)
    short_lived.verify(expiring, now + 499.milliseconds).route.should eq("Counter")
    expect_raises(LF::LiveView::InvalidMountTokenError) do
      short_lived.verify(expiring, now + 501.milliseconds)
    end

    expect_raises(LF::LiveView::ConfigurationError, "at least 32 bytes") do
      LF::LiveView::MountToken.new("short")
    end

    marked = LF::LiveView::Rendered.opaque("\n<!-- component --><section>ok</section>")
      .with_component_root(7_i64, "opal-live-root").to_html
    marked.should contain(%(<section data-phx-component="7" data-phx-view="opal-live-root">))
    expect_raises(ArgumentError, "must render one root HTML element") do
      LF::LiveView::Rendered.opaque("text<section>invalid</section>")
        .with_component_root(7_i64, "opal-live-root")
    end
  end

  it "rejects route collisions and invalid component trees" do
    endpoint = LF::LiveView::Endpoint.new("h" * 32)
    endpoint.page("/counter", LiveViewSpecCounter) { |_scope| LiveViewSpecCounter.new }
    router = LF::HTTP::Router.new
    router.get("//counter/") { |_context, _params| }
    expect_raises(LF::LiveView::ConfigurationError, "conflicts with an existing route") do
      endpoint.mount(router)
    end

    LiveViewSpecRecursiveComponent.reset
    recursive = LiveViewSpecRecursiveComponents.new
    request = HTTP::Request.new("GET", "/recursive-components")
    recursive.__opal_mount(LF::LiveView::MountContext.new(
      request,
      {} of String => String,
      request.resource,
      true
    ))
    expect_raises(LF::LiveView::RecursiveComponentError) do
      recursive.__opal_render
    end
    LiveViewSpecRecursiveComponent.destroy_count.should eq(1)
    recursive.__opal_disconnect

    LiveViewSpecDeepComponent.reset
    deep = LiveViewSpecDeepComponents.new
    deep.__opal_mount(LF::LiveView::MountContext.new(
      request,
      {} of String => String,
      request.resource,
      true
    ))
    expect_raises(LF::LiveView::ComponentNestingError) do
      deep.__opal_render
    end
    LiveViewSpecDeepComponent.destroy_count.should eq(LF::LiveView::View::MAX_COMPONENT_DEPTH)
  ensure
    recursive.try(&.__opal_disconnect)
    deep.try(&.__opal_disconnect)
  end

  it "renders Phoenix root metadata and serves the bundled upstream client" do
    live_view_spec_server("a" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter?source=spec")
      response.status.should eq(HTTP::Status::OK)
      response.body.should contain("data-phx-main")
      response.body.should contain("data-phx-session")
      response.body.should contain("data-phx-static")
      response.body.should contain(%(<script type="module" src="/_opal/live.js">))

      client = HTTP::Client.get("http://#{address.address}:#{address.port}/_opal/live.js")
      client.status.should eq(HTTP::Status::OK)
      client.body.should contain("Phoenix and Phoenix LiveView under the MIT license")
      client.body.should contain("2.0.0")
      client.body.should_not contain("export class OpalLiveView")
    end
  end

  it "joins, diffs events, and acknowledges Phoenix heartbeats" do
    live_view_spec_server("b" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter")
      headers = HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      websocket = phoenix_socket(address, headers)

      joined = phoenix_join(websocket, live_session(response.body), "http://#{address.address}:#{address.port}/counter")
      joined[0].as_s.should eq("1")
      joined[1].as_s.should eq("1")
      joined[2].as_s.should eq("lv:opal-live-root")
      join_response = phoenix_response(joined)
      join_response["liveview_version"].as_s.should eq("1.2.11")
      rendered = join_response["rendered"].as_h
      rendered["s"].as_a.size.should eq(3)
      rendered["0"].as_s.should eq("0")
      rendered["1"].as_s.should eq("yes")
      rendered.has_key?("r").should be_false

      phoenix_send(websocket, "1", "2", "lv:opal-live-root", "event", {
        type: "click", event: "increment", value: {source: "spec"},
      })
      event_response = phoenix_response(phoenix_receive(websocket))
      diff = event_response["diff"].as_h
      diff["0"].as_s.should eq("1")
      diff["t"].as_s.should eq("Counter 1")

      phoenix_send(websocket, "1", "3", "lv:opal-live-root", "unsupported", {} of String => String)
      unsupported = phoenix_receive(websocket)[4].as_h
      unsupported["status"].as_s.should eq("error")
      unsupported["response"]["reason"].as_s.should eq("unsupported_event")

      phoenix_send(websocket, nil, "9", "phoenix", "heartbeat", {} of String => String)
      heartbeat = phoenix_receive(websocket)
      heartbeat[0].raw.should be_nil
      heartbeat[1].as_s.should eq("9")
      heartbeat[2].as_s.should eq("phoenix")
      phoenix_response(heartbeat).should be_empty
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "routes CIDs and emits native component-only diffs" do
    live_view_spec_server("c" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/components")
      websocket = phoenix_socket(
        address,
        HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      rendered = phoenix_response(
        phoenix_join(websocket, live_session(response.body), "http://#{address.address}:#{address.port}/components")
      )["rendered"].as_h
      left_cid = rendered["0"].as_i64
      right_cid = rendered["1"].as_i64
      left_cid.should_not eq(right_cid)
      components = rendered["c"].as_h
      components[left_cid.to_s]["r"].as_i.should eq(1)
      components[right_cid.to_s]["r"].as_i.should eq(1)

      phoenix_send(websocket, "1", "2", "lv:opal-live-root", "event", {
        type: "click", event: "increment", value: nil, cid: left_cid,
      })
      diff = phoenix_response(phoenix_receive(websocket))["diff"].as_h
      diff.has_key?("0").should be_false
      component_diffs = diff["c"].as_h
      component_diffs.keys.should eq([left_cid.to_s])
      component_diffs[left_cid.to_s].as_h.values.any? do |value|
        value.as_s? == "1"
      end.should be_true

      phoenix_send(websocket, "1", "3", "lv:opal-live-root", "event", {
        type: "click", event: "increment", value: nil, cid: 999_999,
      })
      error = phoenix_receive(websocket)[4].as_h
      error["status"].as_s.should eq("error")
      error["response"]["reason"].as_s.should eq("unknown_target")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "encodes hook replies and pushed events in the upstream diff" do
    live_view_spec_server("d" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/hooks")
      websocket = phoenix_socket(
        address,
        HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      phoenix_join(websocket, live_session(response.body), "http://#{address.address}:#{address.port}/hooks")

      phoenix_send(websocket, "1", "2", "lv:opal-live-root", "event", {
        type: "hook", event: "hook_event", value: {message: "from hook"},
      })
      diff = phoenix_response(phoenix_receive(websocket))["diff"].as_h
      diff["0"].as_s.should eq("from hook")
      diff["r"].as_h.should eq({
        "accepted" => JSON::Any.new(true),
        "message"  => JSON::Any.new("from hook"),
      })
      pushed = diff["e"].as_a.first.as_a
      pushed[0].as_s.should eq("hook_notice")
      pushed[1]["message"].as_s.should eq("from hook")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "encodes native Phoenix stream comprehensions and operations" do
    live_view_spec_server("e" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/streams")
      websocket = phoenix_socket(
        address,
        HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      joined = phoenix_response(
        phoenix_join(websocket, live_session(response.body), "http://#{address.address}:#{address.port}/streams")
      )["rendered"].as_h
      stream = joined["0"].as_h
      stream["s"].as_a.map(&.as_s).should eq(["", ""])
      keyed = stream["k"].as_h
      keyed["kc"].as_i.should eq(2)
      keyed["0"]["0"].as_s.should contain("stream-1")
      keyed["1"]["0"].as_s.should contain("stream-2")
      metadata = stream["stream"].as_a
      metadata[0].as_s.should eq("0")
      metadata[1].as_a.map { |insert| insert.as_a[0].as_s }.should eq(["stream-1", "stream-2"])
      metadata[2].as_a.should be_empty
      metadata[3].as_bool.should be_true

      phoenix_send(websocket, "1", "2", "lv:opal-live-root", "event", {
        type: "click", event: "prepend", value: nil,
      })
      stream = phoenix_response(phoenix_receive(websocket))["diff"]["0"].as_h
      stream["k"]["kc"].as_i.should eq(1)
      stream["k"]["0"]["0"].as_s.should contain("stream-3")
      insert = stream["stream"].as_a[1].as_a.first.as_a
      insert[0].as_s.should eq("stream-3")
      insert[1].as_i.should eq(0)
      insert[2].as_i.should eq(2)
      insert[3].as_bool.should be_false

      phoenix_send(websocket, "1", "3", "lv:opal-live-root", "event", {
        type: "click", event: "delete", value: nil,
      })
      deleted = phoenix_response(phoenix_receive(websocket))["diff"]["0"].as_h
      deleted["k"]["kc"].as_i.should eq(0)
      deleted["stream"].as_a[2].as_a.map(&.as_s).should eq(["stream-2"])

      phoenix_send(websocket, "1", "4", "lv:opal-live-root", "event", {
        type: "click", event: "reset", value: nil,
      })
      reset = phoenix_response(phoenix_receive(websocket))["diff"]["0"].as_h
      reset["k"]["0"]["0"].as_s.should contain("stream-9")
      reset["stream"].as_a[3].as_bool.should be_true
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "encodes native keyed comprehension inserts, moves, updates, and removals" do
    live_view_spec_server("k" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/keyed")
      websocket = phoenix_socket(
        address,
        HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      joined = phoenix_response(
        phoenix_join(websocket, live_session(response.body), "http://#{address.address}:#{address.port}/keyed")
      )["rendered"]["0"].as_h
      joined["s"].as_a.map(&.as_s).should eq([%(<li id="keyed-), %(">), "</li>"])
      keyed = joined["k"].as_h
      keyed["kc"].as_i.should eq(3)
      keyed["0"]["0"].as_s.should eq("first")
      keyed["0"]["1"].as_s.should eq("First")

      phoenix_send(websocket, "1", "2", "lv:opal-live-root", "event", {
        type: "click", event: "reverse_update", value: nil,
      })
      moved = phoenix_response(phoenix_receive(websocket))["diff"]["0"].as_h
      moved.has_key?("s").should be_false
      moved["k"]["kc"].as_i.should eq(3)
      moved["k"]["km"].as_bool.should be_true
      moved["k"]["0"].as_a[0].as_i.should eq(2)
      moved["k"]["0"].as_a[1]["1"].as_s.should eq("Third updated")
      moved["k"]["2"].as_i.should eq(0)

      phoenix_send(websocket, "1", "3", "lv:opal-live-root", "event", {
        type: "click", event: "update_second", value: nil,
      })
      updated = phoenix_response(phoenix_receive(websocket))["diff"]["0"].as_h
      updated.has_key?("s").should be_false
      updated["k"]["kc"].as_i.should eq(3)
      updated["k"]["1"]["1"].as_s.should eq("Second updated")

      phoenix_send(websocket, "1", "4", "lv:opal-live-root", "event", {
        type: "click", event: "remove_third", value: nil,
      })
      removed = phoenix_response(phoenix_receive(websocket))["diff"]["0"].as_h
      removed["k"]["kc"].as_i.should eq(2)
      removed["k"]["0"].as_i.should eq(1)
      removed["k"]["1"].as_i.should eq(2)

      phoenix_send(websocket, "1", "5", "lv:opal-live-root", "event", {
        type: "click", event: "append_fourth", value: nil,
      })
      inserted = phoenix_response(phoenix_receive(websocket))["diff"]["0"].as_h
      inserted.has_key?("s").should be_false
      inserted["k"]["kc"].as_i.should eq(3)
      inserted["k"]["2"]["0"].as_s.should eq("fourth")
      inserted["k"]["2"]["1"].as_s.should eq("Fourth")

      phoenix_send(websocket, "1", "6", "lv:opal-live-root", "event", {
        type: "click", event: "clear", value: nil,
      })
      cleared = phoenix_response(phoenix_receive(websocket))["diff"]["0"].as_h
      cleared["s"].as_a.map(&.as_s).should eq([""])
      cleared["k"]["kc"].as_i.should eq(0)

      phoenix_send(websocket, "1", "7", "lv:opal-live-root", "event", {
        type: "click", event: "append_fourth", value: nil,
      })
      restored = phoenix_response(phoenix_receive(websocket))["diff"]["0"].as_h
      restored["s"].as_a.map(&.as_s).should eq([%(<li id="keyed-), %(">), "</li>"])
      restored["k"]["kc"].as_i.should eq(1)
      restored["k"]["0"]["0"].as_s.should eq("fourth")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "validates keyed comprehension keys and entry templates" do
    one = "one"
    two = "two"
    item = LF::LiveView::HTML.rendered(%(<li>#{one}</li>))
    expect_raises(ArgumentError, "duplicate key") do
      LF::LiveView::HTML.keyed([{1, item}, {1, item}]) { |entry| entry }
    end

    expect_raises(ArgumentError, "same static template") do
      LF::LiveView::HTML.keyed([
        {1, LF::LiveView::HTML.rendered(%(<li>#{one}</li>))},
        {2, LF::LiveView::HTML.rendered(%(<p>#{two}</p>))},
      ]) { |entry| entry }
    end
  end

  it "uses the current join URL and handles client and server live patches" do
    live_view_spec_server("f" * 32) do |address|
      response = HTTP::Client.get(
        "http://#{address.address}:#{address.port}/navigation/initial?tab=first"
      )
      websocket = phoenix_socket(
        address,
        HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      joined = phoenix_response(phoenix_join(
        websocket,
        live_session(response.body),
        "http://#{address.address}:#{address.port}/navigation/rejoined?tab=current"
      ))["rendered"].as_h
      joined["0"].as_s.should eq("rejoined")
      joined["1"].as_s.should eq("current")

      phoenix_send(websocket, "1", "2", "lv:opal-live-root", "live_patch", {
        url: "http://#{address.address}:#{address.port}/navigation/second?tab=details",
      })
      patched = phoenix_response(phoenix_receive(websocket))["diff"].as_h
      patched["0"].as_s.should eq("second")
      patched["1"].as_s.should eq("details")

      phoenix_send(websocket, "1", "3", "lv:opal-live-root", "live_patch", {
        url: "https://evil.example/navigation/second?tab=stolen",
      })
      invalid = phoenix_receive(websocket)[4].as_h
      invalid["status"].as_s.should eq("error")
      invalid["response"]["reason"].as_s.should eq("invalid_navigation")

      phoenix_send(websocket, "1", "4", "lv:opal-live-root", "event", {
        type: "click", event: "server_replace", value: nil,
      })
      navigation = phoenix_response(phoenix_receive(websocket))["live_patch"].as_h
      navigation["to"].as_s.should eq("/navigation/replaced?tab=pushed")
      navigation["kind"].as_s.should eq("replace")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "pushes serialized server-side updates as channel diffs" do
    live_view_spec_server("g" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/push")
      websocket = phoenix_socket(
        address,
        HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      phoenix_join(websocket, live_session(response.body), "http://#{address.address}:#{address.port}/push")
      LiveViewSpecPush.wait_until_mounted.push(7)

      pushed = phoenix_receive(websocket)
      pushed[1].raw.should be_nil
      pushed[3].as_s.should eq("diff")
      pushed[4]["s"].as_a.first.as_s.should contain(">7</output>")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "reruns guards for live patches" do
    live_view_spec_server("h" * 32) do |address|
      response = HTTP::Client.get(
        "http://#{address.address}:#{address.port}/navigation/allowed"
      )
      websocket = phoenix_socket(
        address,
        HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      closed = Channel(HTTP::WebSocket::CloseCode).new(1)
      websocket.on_close { |code, _reason| closed.send(code) }
      phoenix_join(websocket, live_session(response.body), "http://#{address.address}:#{address.port}/navigation/allowed")

      phoenix_send(websocket, "1", "2", "lv:opal-live-root", "live_patch", {
        url: "http://#{address.address}:#{address.port}/navigation/allowed?tab=blocked",
      })
      websocket.receive?.should be_nil
      closed.receive.should eq(HTTP::WebSocket::CloseCode::PolicyViolation)
    ensure
      websocket.try(&.close)
    end
  end

  it "destroys unmanaged views after HTTP and connected lifecycles" do
    live_view_spec_server("i" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/disposable")
      LiveViewSpecDisposable.wait_until_destroyed
      websocket = phoenix_socket(
        address,
        HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      phoenix_join(websocket, live_session(response.body), "http://#{address.address}:#{address.port}/disposable")
      websocket.close
      LiveViewSpecDisposable.wait_until_destroyed
    ensure
      websocket.try(&.close)
    end
  end

  it "enforces guards and connected-mount authorization" do
    live_view_spec_server("k" * 32) do |address|
      origin = "http://#{address.address}:#{address.port}"
      HTTP::Client.get("#{origin}/guarded").status.should eq(HTTP::Status::FORBIDDEN)

      allowed_headers = HTTP::Headers{"X-Live-Access" => "allowed"}
      allowed = HTTP::Client.get("#{origin}/guarded", headers: allowed_headers)
      allowed.status.should eq(HTTP::Status::OK)
      token = live_session(allowed.body)

      denied_socket = phoenix_socket(address, HTTP::Headers{"Origin" => origin})
      denied_close = Channel(HTTP::WebSocket::CloseCode).new(1)
      denied_socket.on_close { |code, _reason| denied_close.send(code) }
      phoenix_send(denied_socket, "1", "1", "lv:opal-live-root", "phx_join", {
        url: "#{origin}/guarded", params: {"_mounts" => 0}, session: token, static: nil,
      })
      denied_socket.receive?.should be_nil
      denied_close.receive.should eq(HTTP::WebSocket::CloseCode::PolicyViolation)

      connected_headers = HTTP::Headers{
        "Origin"        => origin,
        "X-Live-Access" => "allowed",
      }
      allowed_socket = phoenix_socket(address, connected_headers)
      phoenix_response(phoenix_join(allowed_socket, token, "#{origin}/guarded"))
      allowed_socket.close

      forbidden = HTTP::Client.get("#{origin}/forbidden")
      forbidden_socket = phoenix_socket(address, HTTP::Headers{"Origin" => origin})
      forbidden_close = Channel(HTTP::WebSocket::CloseCode).new(1)
      forbidden_socket.on_close { |code, _reason| forbidden_close.send(code) }
      phoenix_send(forbidden_socket, "1", "1", "lv:opal-live-root", "phx_join", {
        url:     "#{origin}/forbidden",
        params:  {"_mounts" => 0},
        session: live_session(forbidden.body),
        static:  nil,
      })
      forbidden_socket.receive?.should be_nil
      forbidden_close.receive.should eq(HTTP::WebSocket::CloseCode::PolicyViolation)
    ensure
      denied_socket.try(&.close)
      allowed_socket.try(&.close)
      forbidden_socket.try(&.close)
    end
  end

  it "closes a joined socket after its idle timeout" do
    live_view_spec_server("l" * 32, idle_timeout: 50.milliseconds) do |address|
      origin = "http://#{address.address}:#{address.port}"
      response = HTTP::Client.get("#{origin}/counter")
      websocket = phoenix_socket(address, HTTP::Headers{"Origin" => origin})
      closed = Channel(HTTP::WebSocket::CloseCode).new(1)
      websocket.on_close { |code, _reason| closed.send(code) }
      phoenix_response(phoenix_join(websocket, live_session(response.body), "#{origin}/counter"))
      websocket.receive?.should be_nil
      closed.receive.should eq(HTTP::WebSocket::CloseCode::GoingAway)
    ensure
      websocket.try(&.close)
    end
  end

  it "keeps client event values out of failure logs and close reasons" do
    backend = Log::MemoryBackend.new
    Log.setup(:trace, backend)

    live_view_spec_server("m" * 32) do |address|
      origin = "http://#{address.address}:#{address.port}"
      response = HTTP::Client.get("#{origin}/failure")
      websocket = phoenix_socket(address, HTTP::Headers{"Origin" => origin})
      closed = Channel({HTTP::WebSocket::CloseCode, String}).new(1)
      websocket.on_close { |code, reason| closed.send({code, reason}) }
      phoenix_response(phoenix_join(websocket, live_session(response.body), "#{origin}/failure"))
      phoenix_send(websocket, "1", "2", "lv:opal-live-root", "event", {
        type: "click", event: "user-controlled-secret", value: {token: "also-secret"},
      })
      websocket.receive?.should be_nil

      code, reason = closed.receive
      code.should eq(HTTP::WebSocket::CloseCode::InternalServerError)
      reason.should eq("event failed")
      entry = backend.entries.find { |item| item.message.includes?("LiveView event failed") }.not_nil!
      entry.message.should contain("route=LiveViewSpecFailure")
      entry.message.should_not contain("user-controlled-secret")
      entry.message.should_not contain("also-secret")
    ensure
      websocket.try(&.close)
    end
  ensure
    Log.setup(:info)
  end

  it "rejects malformed, oversized, idle, and cross-origin connections" do
    live_view_spec_server(
      "j" * 32,
      max_message_bytes: 96,
      join_timeout: 50.milliseconds,
      idle_timeout: 50.milliseconds
    ) do |address|
      origin = "http://#{address.address}:#{address.port}"
      timeout_socket = phoenix_socket(address, HTTP::Headers{"Origin" => origin})
      timeout_close = Channel(HTTP::WebSocket::CloseCode).new(1)
      timeout_socket.on_close { |code, _reason| timeout_close.send(code) }
      timeout_socket.receive?.should be_nil
      timeout_close.receive.should eq(HTTP::WebSocket::CloseCode::PolicyViolation)

      oversized = phoenix_socket(address, HTTP::Headers{"Origin" => origin})
      oversized_close = Channel(HTTP::WebSocket::CloseCode).new(1)
      oversized.on_close { |code, _reason| oversized_close.send(code) }
      oversized.send("[\"#{"x" * 200}\"]")
      oversized.receive?.should be_nil
      oversized_close.receive.should eq(HTTP::WebSocket::CloseCode::MessageTooBig)

      binary = phoenix_socket(address, HTTP::Headers{"Origin" => origin})
      binary_close = Channel(HTTP::WebSocket::CloseCode).new(1)
      binary.on_close { |code, _reason| binary_close.send(code) }
      binary.send(Bytes[1_u8, 2_u8, 3_u8])
      binary.receive?.should be_nil
      binary_close.receive.should eq(HTTP::WebSocket::CloseCode::UnsupportedData)

      headers = HTTP::Headers{
        "Connection" => "Upgrade",
        "Upgrade"    => "websocket",
        "Origin"     => "https://evil.example",
      }
      denied = HTTP::Client.get(
        "http://#{address.address}:#{address.port}/_opal/live/websocket",
        headers: headers
      )
      denied.status.should eq(HTTP::Status::FORBIDDEN)
    ensure
      timeout_socket.try(&.close)
      oversized.try(&.close)
      binary.try(&.close)
    end
  end
end
