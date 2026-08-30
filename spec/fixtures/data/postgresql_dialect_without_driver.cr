require "../../../src/opal/data/dialects/postgresql"

dialect = LF::Data::Dialects::PostgreSQL.new
raise "wrong dialect" unless dialect.name == "postgresql"
