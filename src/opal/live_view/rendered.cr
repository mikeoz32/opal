require "digest/sha256"
require "json"
require "./stream"

module LF::LiveView
  alias RenderedDynamic = String | StreamContent

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
            when String        then dynamic
            when StreamContent then dynamic.to_html
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
        dynamic.commit! if dynamic.is_a?(StreamContent)
      end
    end

    # :nodoc:
    def stream_container_ids : Array(String)
      @dynamics.compact_map do |dynamic|
        dynamic.container_id if dynamic.is_a?(StreamContent)
      end
    end
  end

  alias RenderResult = String | Rendered
end
