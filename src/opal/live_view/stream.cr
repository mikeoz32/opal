require "json"
require "set"

module LF::LiveView
  # One ordered stream-state mutation retained by the connection runtime.
  struct StreamOperation
    getter operation : String
    getter container_id : String
    getter item_id : String?
    getter html : String?
    getter at : Int32?
    getter limit : Int32?
    getter? update_only : Bool

    private def initialize(
      @operation,
      @container_id,
      @item_id = nil,
      @html = nil,
      @at = nil,
      @limit = nil,
      @update_only = false,
    )
    end

    def self.insert(
      container_id : String,
      item_id : String,
      html : String,
      at : Int32,
      limit : Int32?,
      update_only : Bool,
    ) : self
      new("insert", container_id, item_id, html, at, limit, update_only)
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
        json.field "update_only", @update_only
      end
    end
  end

  # :nodoc:
  struct StreamInsert
    getter item_id : String
    getter html : String
    getter at : Int32
    getter limit : Int32?
    getter? update_only : Bool

    def initialize(@item_id, @html, @at, @limit, @update_only)
    end
  end

  # A rendered stream snapshot. Its normal HTML is used by the disconnected
  # render, while `to_diff` emits the keyed-comprehension metadata consumed by
  # Phoenix LiveView's native stream patcher.
  # :nodoc:
  class StreamContent
    getter container_id : String
    getter reference : String
    getter value : String

    @inserts : Array(StreamInsert)
    @delete_ids : Array(String)
    @reset : Bool

    def initialize(
      @container_id,
      @reference,
      @value,
      @inserts,
      @delete_ids,
      @reset,
    )
    end

    def to_html : String
      @value
    end

    def pending? : Bool
      @reset || !@inserts.empty? || !@delete_ids.empty?
    end

    def commit! : Nil
      @inserts.clear
      @delete_ids.clear
      @reset = false
    end

    def ==(other : self) : Bool
      @container_id == other.@container_id &&
        @reference == other.@reference &&
        @value == other.@value &&
        @inserts == other.@inserts &&
        @delete_ids == other.@delete_ids &&
        @reset == other.@reset
    end

    def to_diff : JSON::Any
      keyed = {"kc" => JSON::Any.new(@inserts.size.to_i64)}
      @inserts.each_with_index do |insert, index|
        keyed[index.to_s] = JSON::Any.new({"0" => JSON::Any.new(insert.html)})
      end

      diff = {
        "s" => JSON::Any.new([JSON::Any.new(""), JSON::Any.new("")]),
        "k" => JSON::Any.new(keyed),
      }
      if pending?
        metadata = [
          JSON::Any.new(@reference),
          JSON::Any.new(@inserts.map { |insert| insert_metadata(insert) }),
          JSON::Any.new(@delete_ids.map { |item_id| JSON::Any.new(item_id) }),
        ]
        metadata << JSON::Any.new(true) if @reset
        diff["stream"] = JSON::Any.new(metadata)
      end
      JSON::Any.new(diff)
    end

    private def insert_metadata(insert : StreamInsert) : JSON::Any
      JSON::Any.new([
        JSON::Any.new(insert.item_id),
        JSON::Any.new(insert.at.to_i64),
        insert.limit.try { |limit| JSON::Any.new(limit.to_i64) } || JSON::Any.new(nil),
        JSON::Any.new(insert.update_only?),
      ])
    end
  end
end
