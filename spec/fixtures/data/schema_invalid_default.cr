require "../../../src/opal/data"

table = LF::Data::Schema::TableBuilder.new("todos")
table.bool("completed", default: "false")
