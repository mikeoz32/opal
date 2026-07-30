require "../../../src/opal/data"

class QueryShapeUnionFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter active : Bool

  def initialize(@id, @active)
  end
end

def query_shape_union(
  manager : LF::Data::EntityManager,
  active : Bool?,
)
  query = if active.nil?
            manager.query(QueryShapeUnionFixture)
          else
            manager.query(QueryShapeUnionFixture)
              .where(QueryShapeUnionFixture::Fields.active.eq(active))
          end

  query.limit(10).offset(0).to_a
end
