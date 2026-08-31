require "json"

module LF::LiveView
  # A navigation requested by a connected view.
  struct Navigation
    getter kind : String
    getter to : String
    getter history : String

    private def initialize(@kind, @to, @history)
    end

    def self.patch(to : String, *, replace : Bool = false) : self
      new("patch", to, replace ? "replace" : "push")
    end

    def self.patch(to : String, history : String) : self
      new("patch", to, history)
    end

    def self.navigate(to : String, *, replace : Bool = false) : self
      new("navigate", to, replace ? "replace" : "push")
    end

    def self.navigate(to : String, history : String) : self
      new("navigate", to, history)
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "kind", @kind
        json.field "to", @to
        json.field "history", @history
      end
    end
  end
end
