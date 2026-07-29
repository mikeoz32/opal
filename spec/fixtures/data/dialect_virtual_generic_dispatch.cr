require "../../../src/opal/data/dialects/sqlite"

@[LF::Data::Table("compile_first")]
class CompileFirstEntity
  @[LF::Data::Id]
  getter id : Int64

  getter name : String

  def initialize(@id, @name)
  end
end

@[LF::Data::Table("compile_second")]
class CompileSecondEntity
  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  def initialize(@id)
  end
end

dialect : LF::Data::Dialect = LF::Data::Dialects::SQLite.new

raise "find specialization failed" unless dialect.find_plan(CompileFirstEntity).sql ==
                                            %(SELECT "id", "name" FROM "compile_first" WHERE "id" = ?)
raise "insert specialization failed" unless dialect.insert_plan(CompileSecondEntity).sql ==
                                              %(INSERT INTO "compile_second" DEFAULT VALUES)
