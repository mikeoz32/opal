require "../../../../src/opal/data"

class ValidGeneratedIdEntity
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter title : String

  def initialize(@title : String)
    @id = nil
  end
end

entity = ValidGeneratedIdEntity.new("compile")
raise "constructor changed" unless entity.title == "compile"
raise "entity marker missing" unless ValidGeneratedIdEntity.__lf_entity?
