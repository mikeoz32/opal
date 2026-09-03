require "digest/sha256"
require "json"
require "./stream"

module LF::LiveView
  alias ChildViewFactory = Proc(View)

  # Native Phoenix child-LiveView container embedded in its parent render.
  # The disconnected render carries initial HTML; the connected parent sends
  # an empty container which the child joins on its own channel.
  # :nodoc:
  class ChildViewContent
    getter id : String
    getter parent_id : String
    getter type_name : String
    getter session_token : String

    @html : String

    def initialize(@id, @parent_id, @type_name, @session_token, @html)
    end

    def to_html : String
      String.build do |html|
        html << %(<div id=") << HTML.escape(@id)
        html << %(" data-phx-session=") << HTML.escape(@session_token)
        html << %(" data-phx-static="" data-phx-parent-id=")
        html << HTML.escape(@parent_id) << %(">)
        html << @html << "</div>"
      end
    end

    def ==(other : self) : Bool
      @id == other.@id && @parent_id == other.@parent_id && @type_name == other.@type_name
    end
  end

  # One stable-key entry in a native Phoenix keyed comprehension.
  # :nodoc:
  struct KeyedEntry
    getter key : String
    getter rendered : Rendered

    def initialize(@key, @rendered)
    end
  end

  # A collection rendered with one shared static template and stable entry
  # keys. Phoenix can move retained entries and patch their changed dynamics
  # without resending or recreating their DOM nodes.
  class KeyedContent
    getter entries : Array(KeyedEntry)
    getter fingerprint : String

    @statics : Array(String)

    def initialize(entries : Array(KeyedEntry))
      @entries = entries.dup
      validate_unique_keys!

      if first = @entries.first?
        @statics = first.rendered.statics
        @fingerprint = first.rendered.fingerprint
        unless @entries.all? { |entry| entry.rendered.fingerprint == @fingerprint }
          raise ArgumentError.new("Every keyed comprehension entry must use the same static template")
        end
      else
        @statics = [""]
        @fingerprint = Digest::SHA256.hexdigest(@statics.to_json)
      end
    end

    def statics : Array(String)
      @statics.dup
    end

    def to_html : String
      String.build do |html|
        @entries.each { |entry| html << entry.rendered.to_html }
      end
    end

    def ==(other : self) : Bool
      @fingerprint == other.@fingerprint && @entries == other.@entries
    end

    # :nodoc:
    def commit_streams : Nil
      @entries.each(&.rendered.commit_streams)
    end

    # :nodoc:
    def stream_container_ids : Array(String)
      @entries.flat_map(&.rendered.stream_container_ids)
    end

    # :nodoc:
    def component_contents : Hash(Int64, ComponentContent)
      components = {} of Int64 => ComponentContent
      @entries.each { |entry| components.merge!(entry.rendered.component_contents) }
      components
    end

    private def validate_unique_keys! : Nil
      seen = Set(String).new
      @entries.each do |entry|
        unless seen.add?(entry.key)
          raise ArgumentError.new("Found duplicate key #{entry.key} in keyed comprehension")
        end
      end
    end
  end

  # A connection-local stateful component reference embedded in its parent
  # render. Phoenix receives the CID in the parent tree and the component's
  # own structural diff through the top-level `c` table.
  # :nodoc:
  class ComponentContent
    getter cid : Int64
    getter rendered : Rendered
    getter view_id : String

    @html : String

    def initialize(@cid, @rendered, @view_id)
      @html = @rendered.with_component_root(@cid, @view_id).to_html
    end

    def to_html : String
      @html
    end

    def ==(other : self) : Bool
      @cid == other.@cid && @view_id == other.@view_id
    end
  end

  alias RenderedDynamic = String | StreamContent | ComponentContent | KeyedContent | ChildViewContent

  # A server-rendered template split into immutable static fragments and
  # escaped dynamic values. Matching fingerprints can be updated over the wire
  # by sending only changed dynamic positions.
  struct Rendered
    getter fingerprint : String

    @statics : Array(String)
    @dynamics : Array(RenderedDynamic)

    def initialize(statics : Array(String), dynamics : Array(String))
      initialize(statics, dynamics.map(&.as(RenderedDynamic)))
    end

    def initialize(statics : Array(String), dynamics : Array(RenderedDynamic))
      unless statics.size == dynamics.size + 1
        raise ArgumentError.new("A LiveView render needs exactly one more static fragment than dynamic values")
      end

      @statics = statics.dup
      @dynamics = dynamics.dup
      @fingerprint = Digest::SHA256.hexdigest(@statics.to_json)
    end

    # Compatibility representation for views that still return a complete HTML
    # string. Since the HTML is static from the diff engine's perspective, any
    # change produces a new fingerprint and a complete rendered snapshot.
    def self.opaque(html : String) : self
      new([html], [] of String)
    end

    # :nodoc:
    def self.component(content : ComponentContent) : self
      new(["", ""], [content] of RenderedDynamic)
    end

    # :nodoc:
    def component_content? : ComponentContent?
      return nil unless @statics == ["", ""] && @dynamics.size == 1
      @dynamics.first.as?(ComponentContent)
    end

    def statics : Array(String)
      @statics.dup
    end

    def dynamics : Array(RenderedDynamic)
      @dynamics.dup
    end

    def to_html : String
      String.build do |html|
        @statics.each_with_index do |static, index|
          html << static
          if dynamic = @dynamics[index]?
            html << case dynamic
            when String           then dynamic
            when StreamContent    then dynamic.to_html
            when ComponentContent then dynamic.to_html
            when KeyedContent     then dynamic.to_html
            when ChildViewContent then dynamic.to_html
            end
          end
        end
      end
    end

    # Adds the upstream Phoenix component ownership markers to a stateful
    # component's single root element. Component output is already flattened
    # when embedded in its parent template, so this compatibility transform
    # does not reduce the granularity of the current diff model.
    # :nodoc:
    def with_component_root(cid : Int64, view_id : String) : self
      html = to_html
      match = html.match(/\A(\s*(?:<!--(?s:.*?)-->\s*)*)<[A-Za-z][A-Za-z0-9:-]*/)
      unless match
        raise ArgumentError.new("A LiveView component must render one root HTML element")
      end
      insert_at = match.end(0)
      marked = String.build do |output|
        output << html[0...insert_at]
        output << " data-phx-component=\"" << cid << "\" data-phx-view=\""
        output << view_id << "\""
        output << html[insert_at..]
      end
      Rendered.opaque(marked)
    end

    # Returns changed dynamic positions, or `nil` when the static template
    # changed and the client needs a complete snapshot.
    def diff(previous : self) : Hash(Int32, RenderedDynamic)?
      return nil unless previous.fingerprint == fingerprint

      changes = {} of Int32 => RenderedDynamic
      @dynamics.each_with_index do |dynamic, index|
        changes[index] = dynamic unless previous.@dynamics[index] == dynamic
      end
      changes
    end

    # Marks native stream snapshots as delivered so the next ordinary render
    # does not resend already acknowledged operations.
    # :nodoc:
    def commit_streams : Nil
      @dynamics.each do |dynamic|
        case dynamic
        when StreamContent    then dynamic.commit!
        when ComponentContent then dynamic.rendered.commit_streams
        when KeyedContent     then dynamic.commit_streams
        end
      end
    end

    # :nodoc:
    def stream_container_ids : Array(String)
      container_ids = [] of String
      @dynamics.each do |dynamic|
        case dynamic
        when StreamContent    then container_ids << dynamic.container_id
        when ComponentContent then container_ids.concat(dynamic.rendered.stream_container_ids)
        when KeyedContent     then container_ids.concat(dynamic.stream_container_ids)
        end
      end
      container_ids
    end

    # :nodoc:
    def component_contents : Hash(Int64, ComponentContent)
      components = {} of Int64 => ComponentContent
      @dynamics.each do |dynamic|
        case dynamic
        when ComponentContent
          components[dynamic.cid] = dynamic
          components.merge!(dynamic.rendered.component_contents)
        when KeyedContent
          components.merge!(dynamic.component_contents)
        end
      end
      components
    end
  end

  alias RenderResult = String | Rendered
end
