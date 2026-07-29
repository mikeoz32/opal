require "../../../src/opal/data"

module SpoofedGeneratedKeySource
  LastInsertId = LF::Data::SQL::GeneratedKeySource::None
end

class SpoofedGeneratedKeySourceDialect < LF::Data::Dialect
  module Policy
    IDENTIFIER_OPEN        = %(")
    IDENTIFIER_CLOSE       = %(")
    IDENTIFIER_ESCAPE_FROM = %(")
    IDENTIFIER_ESCAPE_TO   = %("")
    PLACEHOLDER_STYLE      = :anonymous
    PLACEHOLDER_TOKEN      = "?"
    EMPTY_INSERT_STYLE     = :default_values
    GENERATED_KEY_SOURCE   = SpoofedGeneratedKeySource::LastInsertId
  end

  STATIC_SQL_POLICY = Policy
  include LF::Data::SQL::StaticPlanCompiler

  def name : String
    "spoofed-generated-key"
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
