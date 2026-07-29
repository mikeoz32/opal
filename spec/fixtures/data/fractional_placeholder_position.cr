require "../../../src/opal/data"

class FractionalPlaceholderPositionDialect < LF::Data::Dialect
  module Policy
    IDENTIFIER_OPEN            = %(")
    IDENTIFIER_CLOSE           = %(")
    IDENTIFIER_ESCAPE_FROM     = %(")
    IDENTIFIER_ESCAPE_TO       = %("")
    PLACEHOLDER_STYLE          = :numbered
    PLACEHOLDER_PREFIX         = "$"
    PLACEHOLDER_FIRST_POSITION = 1.5
    EMPTY_INSERT_STYLE         = :default_values
    GENERATED_KEY_SOURCE       = LF::Data::SQL::GeneratedKeySource::LastInsertId
  end

  STATIC_SQL_POLICY = Policy
  include LF::Data::SQL::StaticPlanCompiler

  def name : String
    "fractional-placeholder"
  end

  def quote_identifier(identifier : String) : String
    identifier
  end

  def placeholder(position : Int32) : String
    "$#{position}"
  end

  def supports?(capability : LF::Data::DialectCapability) : Bool
    false
  end
end
