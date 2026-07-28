require "../../data"

module LF
  module Data
    module Dialects
      class SQLite < LF::Data::Dialect
        def name : String
          "sqlite"
        end

        def quote_identifier(identifier : String) : String
          raise ArgumentError.new("Invalid SQL identifier") if identifier.empty? || identifier.includes?('\0')
          %("#{identifier.gsub("\"", "\"\"")}")
        end

        def placeholder(position : Int32) : String
          "?"
        end

        def find_plan(entity : T.class) : SQL::StatementPlan forall T
          {% begin %}
          {% if table_annotation = T.annotation(LF::Data::Table) %}
            {% if table_annotation[:name] %}
              {% table_name = table_annotation[:name].stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
            {% elsif table_annotation.args.size > 0 %}
              {% table_name = table_annotation.args.first.stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
            {% else %}
              {% table_name = T.name.stringify.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
            {% end %}
          {% else %}
            {% table_name = T.name.stringify.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
          {% end %}

          {% selected_columns = [] of String %}
          {% id_column = nil %}
          {% for ivar in T.instance_vars %}
            {% if column_annotation = ivar.annotation(LF::Data::Column) %}
              {% unless column_annotation[:ignore] %}
                {% if column_annotation[:name] %}
                  {% column_name = column_annotation[:name].stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
                {% else %}
                  {% column_name = ivar.id.stringify %}
                {% end %}
                {% selected_columns << column_name %}
                {% if ivar.annotation(LF::Data::Id) %}
                  {% id_column = column_name %}
                {% end %}
              {% end %}
            {% else %}
              {% column_name = ivar.id.stringify %}
              {% selected_columns << column_name %}
              {% if ivar.annotation(LF::Data::Id) %}
                {% id_column = column_name %}
              {% end %}
            {% end %}
          {% end %}
          {% raise "Entity #{T} must define an LF::Data::Id field" unless id_column %}

          {% quoted_table = table_name.gsub(/"/, "\"\"") %}
          {% quoted_columns = selected_columns.map { |column| "\"" + column.gsub(/"/, "\"\"") + "\"" }.join(", ") %}
          {% quoted_id = id_column.gsub(/"/, "\"\"") %}
          {% sql = "SELECT " + quoted_columns + " FROM \"" + quoted_table + "\" WHERE \"" + quoted_id + "\" = ?" %}
          SQL::StatementPlan.new({{sql}})
          {% end %}
        end

        def insert_plan(entity : T.class) : SQL::InsertPlan forall T
          {% begin %}
          {% if table_annotation = T.annotation(LF::Data::Table) %}
            {% if table_annotation[:name] %}
              {% table_name = table_annotation[:name].stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
            {% elsif table_annotation.args.size > 0 %}
              {% table_name = table_annotation.args.first.stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
            {% else %}
              {% table_name = T.name.stringify.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
            {% end %}
          {% else %}
            {% table_name = T.name.stringify.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
          {% end %}

          {% writable_columns = [] of String %}
          {% id_column = nil %}
          {% generated_id = false %}
          {% for ivar in T.instance_vars %}
            {% if column_annotation = ivar.annotation(LF::Data::Column) %}
              {% unless column_annotation[:ignore] %}
                {% if column_annotation[:name] %}
                  {% column_name = column_annotation[:name].stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
                {% else %}
                  {% column_name = ivar.id.stringify %}
                {% end %}
                {% if id_annotation = ivar.annotation(LF::Data::Id) %}
                  {% id_column = column_name %}
                  {% if id_annotation[:generated] %}
                    {% generated_id = true %}
                  {% else %}
                    {% writable_columns << column_name %}
                  {% end %}
                {% else %}
                  {% writable_columns << column_name %}
                {% end %}
              {% end %}
            {% else %}
              {% column_name = ivar.id.stringify %}
              {% if id_annotation = ivar.annotation(LF::Data::Id) %}
                {% id_column = column_name %}
                {% if id_annotation[:generated] %}
                  {% generated_id = true %}
                {% else %}
                  {% writable_columns << column_name %}
                {% end %}
              {% else %}
                {% writable_columns << column_name %}
              {% end %}
            {% end %}
          {% end %}
          {% raise "Entity #{T} must define an LF::Data::Id field" unless id_column %}

          {% quoted_table = table_name.gsub(/"/, "\"\"") %}
          {% if writable_columns.empty? %}
            {% sql = "INSERT INTO \"" + quoted_table + "\" DEFAULT VALUES" %}
          {% else %}
            {% quoted_columns = writable_columns.map { |column| "\"" + column.gsub(/"/, "\"\"") + "\"" }.join(", ") %}
            {% placeholders = writable_columns.map { |_| "?" }.join(", ") %}
            {% sql = "INSERT INTO \"" + quoted_table + "\" (" + quoted_columns + ") VALUES (" + placeholders + ")" %}
          {% end %}
          {% if generated_id %}
            SQL::InsertPlan.new({{sql}}, SQL::GeneratedKeySource::LastInsertId, {{id_column}})
          {% else %}
            SQL::InsertPlan.new({{sql}}, SQL::GeneratedKeySource::None, nil)
          {% end %}
          {% end %}
        end

        def update_plan(entity : T.class) : SQL::StatementPlan forall T
          {% begin %}
          {% if table_annotation = T.annotation(LF::Data::Table) %}
            {% if table_annotation[:name] %}
              {% table_name = table_annotation[:name].stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
            {% elsif table_annotation.args.size > 0 %}
              {% table_name = table_annotation.args.first.stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
            {% else %}
              {% table_name = T.name.stringify.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
            {% end %}
          {% else %}
            {% table_name = T.name.stringify.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
          {% end %}

          {% assignments = [] of String %}
          {% id_column = nil %}
          {% version_column = nil %}
          {% for ivar in T.instance_vars %}
            {% if column_annotation = ivar.annotation(LF::Data::Column) %}
              {% unless column_annotation[:ignore] %}
                {% if column_annotation[:name] %}
                  {% column_name = column_annotation[:name].stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
                {% else %}
                  {% column_name = ivar.id.stringify %}
                {% end %}
                {% if ivar.annotation(LF::Data::Id) %}
                  {% id_column = column_name %}
                {% else %}
                  {% assignments << column_name %}
                {% end %}
                {% if ivar.annotation(LF::Data::Version) %}
                  {% version_column = column_name %}
                {% end %}
              {% end %}
            {% else %}
              {% column_name = ivar.id.stringify %}
              {% if ivar.annotation(LF::Data::Id) %}
                {% id_column = column_name %}
              {% else %}
                {% assignments << column_name %}
              {% end %}
              {% if ivar.annotation(LF::Data::Version) %}
                {% version_column = column_name %}
              {% end %}
            {% end %}
          {% end %}
          {% raise "Entity #{T} must define an LF::Data::Id field" unless id_column %}
          {% quoted_table = table_name.gsub(/"/, "\"\"") %}
          {% quoted_assignments = assignments.map { |column| "\"" + column.gsub(/"/, "\"\"") + "\" = ?" }.join(", ") %}
          {% quoted_id = id_column.gsub(/"/, "\"\"") %}
          {% if version_column %}
            {% quoted_version = version_column.gsub(/"/, "\"\"") %}
            {% sql = "UPDATE \"" + quoted_table + "\" SET " + quoted_assignments + " WHERE \"" + quoted_id + "\" = ? AND \"" + quoted_version + "\" = ?" %}
          {% else %}
            {% sql = "UPDATE \"" + quoted_table + "\" SET " + quoted_assignments + " WHERE \"" + quoted_id + "\" = ?" %}
          {% end %}
          SQL::StatementPlan.new({{sql}})
          {% end %}
        end

        def delete_plan(entity : T.class) : SQL::StatementPlan forall T
          {% begin %}
          {% if table_annotation = T.annotation(LF::Data::Table) %}
            {% if table_annotation[:name] %}
              {% table_name = table_annotation[:name].stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
            {% elsif table_annotation.args.size > 0 %}
              {% table_name = table_annotation.args.first.stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
            {% else %}
              {% table_name = T.name.stringify.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
            {% end %}
          {% else %}
            {% table_name = T.name.stringify.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
          {% end %}

          {% id_column = nil %}
          {% version_column = nil %}
          {% for ivar in T.instance_vars %}
            {% if column_annotation = ivar.annotation(LF::Data::Column) %}
              {% unless column_annotation[:ignore] %}
                {% if column_annotation[:name] %}
                  {% column_name = column_annotation[:name].stringify.gsub(/^"/, "").gsub(/"$/, "").gsub(/\\\"/, "\"") %}
                {% else %}
                  {% column_name = ivar.id.stringify %}
                {% end %}
                {% if ivar.annotation(LF::Data::Id) %}
                  {% id_column = column_name %}
                {% end %}
                {% if ivar.annotation(LF::Data::Version) %}
                  {% version_column = column_name %}
                {% end %}
              {% end %}
            {% else %}
              {% column_name = ivar.id.stringify %}
              {% if ivar.annotation(LF::Data::Id) %}
                {% id_column = column_name %}
              {% end %}
              {% if ivar.annotation(LF::Data::Version) %}
                {% version_column = column_name %}
              {% end %}
            {% end %}
          {% end %}
          {% raise "Entity #{T} must define an LF::Data::Id field" unless id_column %}
          {% quoted_table = table_name.gsub(/"/, "\"\"") %}
          {% quoted_id = id_column.gsub(/"/, "\"\"") %}
          {% if version_column %}
            {% quoted_version = version_column.gsub(/"/, "\"\"") %}
            {% sql = "DELETE FROM \"" + quoted_table + "\" WHERE \"" + quoted_id + "\" = ? AND \"" + quoted_version + "\" = ?" %}
          {% else %}
            {% sql = "DELETE FROM \"" + quoted_table + "\" WHERE \"" + quoted_id + "\" = ?" %}
          {% end %}
          SQL::StatementPlan.new({{sql}})
          {% end %}
        end

        def supports?(capability : DialectCapability) : Bool
          case capability
          when .last_insert_id?, .transactional_ddl?, .add_column?, .rename_column?, .foreign_key_ddl?
            true
          when .returning_row?
            false
          else
            false
          end
        end
      end
    end
  end
end
