require "json"

module LF::LiveView
  # One ordered stream-state mutation retained by the connection runtime.
  struct StreamOperation
    getter operation : String
    getter container_id : String
    getter item_id : String?
    getter html : String?
    getter at : Int32?
    getter limit : Int32?

    private def initialize(
      @operation,
      @container_id,
      @item_id = nil,
      @html = nil,
      @at = nil,
      @limit = nil,
    )
    end

    def self.insert(
      container_id : String,
      item_id : String,
      html : String,
      at : Int32,
      limit : Int32?,
    ) : self
      new("insert", container_id, item_id, html, at, limit)
    end

    def self.delete(container_id : String, item_id : String) : self
      new("delete", container_id, item_id)
    end

    def self.reset(container_id : String) : self
      new("reset", container_id)
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "op", @operation
        json.field "container", @container_id
        if item_id = @item_id
          json.field "id", item_id
        end
        if html = @html
          json.field "html", html
        end
        if at = @at
          json.field "at", at
        end
        if limit = @limit
          json.field "limit", limit
        end
      end
    end
  end
end
