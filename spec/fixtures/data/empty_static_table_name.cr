require "../../../src/opal/data"

@[LF::Data::Table("")]
class EmptyStaticTableNameEntity
  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

class InvalidStaticIdentifierDialect < LF::Data::Dialect
  module Policy
    IDENTIFIER_OPEN        = %(")
    IDENTIFIER_CLOSE       = %(")
    IDENTIFIER_ESCAPE_FROM = %(")
    IDENTIFIER_ESCAPE_TO   = %("")
    PLACEHOLDER_STYLE      = :anonymous
    PLACEHOLDER_TOKEN      = "?"
    EMPTY_INSERT_STYLE     = :default_values
    GENERATED_KEY_SOURCE   = LF::Data::SQL::GeneratedKeySource::LastInsertId
  end

  STATIC_SQL_POLICY = Policy
  include LF::Data::SQL::StaticPlanCompiler

  def name : String
    "invalid-identifier"
  end

  def quote_identifier(identifier : String) : String
    identifier
  end

  def placeholder(position : Int32) : String
    "?"
  end

  def supports?(capability : LF::Data::DialectCapability) : Bool
    false
  end
end

InvalidStaticIdentifierDialect.new.find_plan(EmptyStaticTableNameEntity)
