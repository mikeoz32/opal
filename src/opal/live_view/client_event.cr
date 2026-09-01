require "json"

module LF::LiveView
  # An application event delivered to every matching browser hook after the
  # associated DOM update has been applied.
  struct PushedEvent
    getter name : String
    getter payload : JSON::Any

    def initialize(@name, @payload)
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "event", @name
        json.field "payload" do
          @payload.to_json(json)
        end
      end
    end
  end

  # Distinguishes an explicit JSON null event reply from no reply.
  struct EventReply
    getter value : JSON::Any

    def initialize(@value)
    end
  end
end
