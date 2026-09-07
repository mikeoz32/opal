require "opal/data"
require "opal/data/dialects/postgresql"

struct CreatedPayload
  include JSON::Serializable

  getter created_id : String

  def initialize(@created_id : String)
  end
end

struct ArchivedPayload
  include JSON::Serializable

  getter reason : String

  def initialize(@reason : String)
  end
end

alias EntityChangePayload = CreatedPayload | ArchivedPayload

module EntityChangePayloadCodec
  def self.load(
    parser : JSON::PullParser,
    type : EntityChangePayload.class,
  ) : EntityChangePayload
    EntityChangePayload.new(parser)
  end

  def self.dump(
    value : EntityChangePayload,
    builder : JSON::Builder,
  ) : Nil
    value.to_json(builder)
  end
end

@[LF::Data::Table("entity_changes")]
class EntityChange
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(type: :jsonb, codec: EntityChangePayloadCodec)]
  property payload : EntityChangePayload

  @[LF::Data::Column(type: :json)]
  property labels : Array(String)

  @[LF::Data::Column(type: :jsonb)]
  property metadata : Hash(String, String)?

  def initialize(@id, @payload, @labels, @metadata)
  end
end

class CreateEntityChanges < LF::Data::Migration
  def version : Int64
    1_i64
  end

  def name : String
    "create_entity_changes"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("entity_changes") do |table|
      table.int64("id", null: false)
      table.jsonb("payload", null: false)
      table.json("labels", null: false)
      table.jsonb("metadata")
      table.primary_key("id")
    end
  end
end

def ready_changes(manager : LF::Data::EntityManager) : Array(EntityChange)
  fields = EntityChange::Fields

  manager.repository(EntityChange).query
    .where(fields.payload.jsonb_contains({created_id: "change-42"}))
    .where(fields.payload.jsonb_has_key("created_id"))
    .to_a
end
