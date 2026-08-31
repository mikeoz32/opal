require "digest/sha256"
require "json"

module LF::LiveView
  # A server-rendered template split into immutable static fragments and
  # escaped dynamic values. Matching fingerprints can be updated over the wire
  # by sending only changed dynamic positions.
  struct Rendered
    getter fingerprint : String

    @statics : Array(String)
    @dynamics : Array(String)

    def initialize(statics : Array(String), dynamics : Array(String))
      unless statics.size == dynamics.size + 1
        raise ArgumentError.new("A LiveView render needs exactly one more static fragment than dynamic values")
      end

      @statics = statics.dup
      @dynamics = dynamics.dup
      @fingerprint = Digest::SHA256.hexdigest(@statics.to_json)
    end

    # Compatibility representation for views that still return a complete HTML
    # string. Since the HTML is static from the diff engine's perspective, any
    # change produces a new fingerprint and a complete protocol-v2 snapshot.
    def self.opaque(html : String) : self
      new([html], [] of String)
    end

    def statics : Array(String)
      @statics.dup
    end

    def dynamics : Array(String)
      @dynamics.dup
    end

    def to_html : String
      String.build do |html|
        @statics.each_with_index do |static, index|
          html << static
          if dynamic = @dynamics[index]?
            html << dynamic
          end
        end
      end
    end

    # Returns changed dynamic positions, or `nil` when the static template
    # changed and the client needs a complete snapshot.
    def diff(previous : self) : Hash(Int32, String)?
      return nil unless previous.fingerprint == fingerprint

      changes = {} of Int32 => String
      @dynamics.each_with_index do |dynamic, index|
        changes[index] = dynamic unless previous.@dynamics[index] == dynamic
      end
      changes
    end
  end

  alias RenderResult = String | Rendered
end
