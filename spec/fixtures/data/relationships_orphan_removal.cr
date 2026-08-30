require "../../../src/opal/data"

class OrphanRemovalOwner
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::HasMany(
    foreign_key: "owner_id",
    orphan_removal: true,
  )]
  getter children : Array(OrphanRemovalChild) = [] of OrphanRemovalChild

  def initialize(@id : Int64)
  end
end

class OrphanRemovalChild
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter owner_id : Int64

  @[LF::Data::BelongsTo(foreign_key: "owner_id")]
  property owner : OrphanRemovalOwner?

  def initialize(
    @id : Int64,
    @owner_id : Int64,
    @owner : OrphanRemovalOwner? = nil,
  )
  end
end
