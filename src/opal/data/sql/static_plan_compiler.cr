module LF
  module Data
    module SQL
      module StaticPlanCompiler
        macro included
          {% unless @type.has_constant?("STATIC_SQL_POLICY") %}
            {% raise "#{@type} must define STATIC_SQL_POLICY before including LF::Data::SQL::StaticPlanCompiler" %}
          {% end %}
          {% policy = @type.constant("STATIC_SQL_POLICY").resolve %}
          {% for constant_name in {
                                    "IDENTIFIER_OPEN",
                                    "IDENTIFIER_CLOSE",
                                    "IDENTIFIER_ESCAPE_FROM",
                                    "IDENTIFIER_ESCAPE_TO",
                                    "PLACEHOLDER_STYLE",
                                    "EMPTY_INSERT_STYLE",
                                    "GENERATED_KEY_SOURCE",
                                  } %}
            {% unless policy.has_constant?(constant_name) %}
              {% raise "#{@type} static SQL policy must define #{constant_name}" %}
            {% end %}
          {% end %}
          {% for constant_name in {
                                    "IDENTIFIER_OPEN",
                                    "IDENTIFIER_CLOSE",
                                    "IDENTIFIER_ESCAPE_FROM",
                                    "IDENTIFIER_ESCAPE_TO",
                                  } %}
            {% unless policy.constant(constant_name).is_a?(StringLiteral) %}
              {% raise "#{@type} static SQL policy #{constant_name} must be a String literal" %}
            {% end %}
          {% end %}

          {% placeholder_style = policy.constant("PLACEHOLDER_STYLE") %}
          {% if placeholder_style == :anonymous %}
            {% unless policy.has_constant?("PLACEHOLDER_TOKEN") %}
              {% raise "#{@type} anonymous placeholder policy must define PLACEHOLDER_TOKEN" %}
            {% end %}
            {% unless policy.constant("PLACEHOLDER_TOKEN").is_a?(StringLiteral) %}
              {% raise "#{@type} static SQL policy PLACEHOLDER_TOKEN must be a String literal" %}
            {% end %}
          {% elsif placeholder_style == :numbered %}
            {% unless policy.has_constant?("PLACEHOLDER_PREFIX") && policy.has_constant?("PLACEHOLDER_FIRST_POSITION") %}
              {% raise "#{@type} numbered placeholder policy must define PLACEHOLDER_PREFIX and PLACEHOLDER_FIRST_POSITION" %}
            {% end %}
            {% unless policy.constant("PLACEHOLDER_PREFIX").is_a?(StringLiteral) %}
              {% raise "#{@type} static SQL policy PLACEHOLDER_PREFIX must be a String literal" %}
            {% end %}
            {% first_position = policy.constant("PLACEHOLDER_FIRST_POSITION") %}
            {% unless first_position.is_a?(NumberLiteral) %}
              {% raise "#{@type} static SQL policy PLACEHOLDER_FIRST_POSITION must be an integer literal" %}
            {% end %}
            {% integer_kinds = {:i8, :u8, :i16, :u16, :i32, :u32, :i64, :u64, :i128, :u128} %}
            {% unless integer_kinds.includes?(first_position.kind) %}
              {% raise "#{@type} static SQL policy PLACEHOLDER_FIRST_POSITION must be an integer literal" %}
            {% end %}
          {% else %}
            {% raise "#{@type} static SQL policy has unsupported PLACEHOLDER_STYLE #{placeholder_style}" %}
          {% end %}

          {% empty_insert_style = policy.constant("EMPTY_INSERT_STYLE") %}
          {% unless empty_insert_style == :default_values || empty_insert_style == :empty_columns %}
            {% raise "#{@type} static SQL policy has unsupported EMPTY_INSERT_STYLE #{empty_insert_style}" %}
          {% end %}

          {% generated_key_source = policy.constant("GENERATED_KEY_SOURCE") %}
          {% unless generated_key_source.is_a?(Path) &&
                      generated_key_source.names.size >= 2 &&
                      generated_key_source.names[-2].stringify == "GeneratedKeySource" %}
            {% raise "#{@type} static SQL policy has unsupported generated key source #{generated_key_source}" %}
          {% end %}
          {% generated_key_source_value = generated_key_source.resolve %}
          {% generated_key_source_type = LF::Data::SQL::GeneratedKeySource.resolve %}
          {% last_insert_id_value = generated_key_source_type.constant("LastInsertId") %}
          {% returning_row_value = generated_key_source_type.constant("ReturningRow") %}
          {% unless generated_key_source_value == last_insert_id_value || generated_key_source_value == returning_row_value %}
            {% raise "#{@type} static SQL policy has unsupported generated key source #{generated_key_source}" %}
          {% end %}

          {% verbatim do %}
            def find_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
              {% begin %}
                {% policy = @type.constant("STATIC_SQL_POLICY").resolve %}
                {% identifier_open = policy.constant("IDENTIFIER_OPEN") %}
                {% identifier_close = policy.constant("IDENTIFIER_CLOSE") %}
                {% identifier_escape_from = policy.constant("IDENTIFIER_ESCAPE_FROM") %}
                {% identifier_escape_to = policy.constant("IDENTIFIER_ESCAPE_TO") %}
                {% placeholder_style = policy.constant("PLACEHOLDER_STYLE") %}

                {% if placeholder_style == :anonymous %}
                  {% id_placeholder = policy.constant("PLACEHOLDER_TOKEN") %}
                {% elsif placeholder_style == :numbered %}
                  {% placeholder_prefix = policy.constant("PLACEHOLDER_PREFIX") %}
                  {% first_position = policy.constant("PLACEHOLDER_FIRST_POSITION") %}
                  {% id_placeholder = placeholder_prefix + first_position.stringify %}
                {% else %}
                  {% raise "#{@type} static SQL policy has unsupported PLACEHOLDER_STYLE #{placeholder_style}" %}
                {% end %}

                {% if table_annotation = T.annotation(LF::Data::Table) %}
                  {% if table_annotation[:name] %}
                    {% table_name = table_annotation[:name] %}
                  {% elsif table_annotation.args.size > 0 %}
                    {% table_name = table_annotation.args.first %}
                  {% else %}
                    {% table_name = T.name.stringify.split("::").last.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
                  {% end %}
                {% else %}
                  {% table_name = T.name.stringify.split("::").last.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
                {% end %}

                {% selected_columns = [] of String %}
                {% id_column = nil %}
                {% for ivar in T.instance_vars %}
                  {% if column_annotation = ivar.annotation(LF::Data::Column) %}
                    {% unless column_annotation[:ignore] %}
                      {% column_name = column_annotation[:name] || ivar.id.stringify %}
                      {% selected_columns << column_name %}
                      {% id_column = column_name if ivar.annotation(LF::Data::Id) %}
                    {% end %}
                  {% else %}
                    {% column_name = ivar.id.stringify %}
                    {% selected_columns << column_name %}
                    {% id_column = column_name if ivar.annotation(LF::Data::Id) %}
                  {% end %}
                {% end %}
                {% raise "Entity #{T} must define an LF::Data::Id field" unless id_column %}
                {% if table_name.empty? || table_name.includes?("\0") %}
                  {% raise "Invalid SQL identifier for #{@type}: table name must not be empty or contain NUL" %}
                {% end %}
                {% for column in selected_columns %}
                  {% if column.empty? || column.includes?("\0") %}
                    {% raise "Invalid SQL identifier for #{@type}: column name must not be empty or contain NUL" %}
                  {% end %}
                {% end %}

                {% quoted_table = identifier_open + table_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                {% quoted_columns = selected_columns.map do |column|
                     identifier_open + column.split(identifier_escape_from).join(identifier_escape_to) + identifier_close
                   end.join(", ") %}
                {% quoted_id = identifier_open + id_column.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                {% sql = "SELECT " + quoted_columns + " FROM " + quoted_table + " WHERE " + quoted_id + " = " + id_placeholder %}
                LF::Data::SQL::StatementPlan.new({{sql}})
              {% end %}
            end

            def insert_plan(entity : T.class) : LF::Data::SQL::InsertPlan forall T
              {% begin %}
                {% policy = @type.constant("STATIC_SQL_POLICY").resolve %}
                {% identifier_open = policy.constant("IDENTIFIER_OPEN") %}
                {% identifier_close = policy.constant("IDENTIFIER_CLOSE") %}
                {% identifier_escape_from = policy.constant("IDENTIFIER_ESCAPE_FROM") %}
                {% identifier_escape_to = policy.constant("IDENTIFIER_ESCAPE_TO") %}
                {% placeholder_style = policy.constant("PLACEHOLDER_STYLE") %}
                {% empty_insert_style = policy.constant("EMPTY_INSERT_STYLE") %}
                {% generated_key_source = policy.constant("GENERATED_KEY_SOURCE") %}

                {% if placeholder_style == :anonymous %}
                  {% placeholder_token = policy.constant("PLACEHOLDER_TOKEN") %}
                {% elsif placeholder_style == :numbered %}
                  {% placeholder_prefix = policy.constant("PLACEHOLDER_PREFIX") %}
                  {% first_position = policy.constant("PLACEHOLDER_FIRST_POSITION") %}
                {% else %}
                  {% raise "#{@type} static SQL policy has unsupported PLACEHOLDER_STYLE #{placeholder_style}" %}
                {% end %}

                {% if table_annotation = T.annotation(LF::Data::Table) %}
                  {% if table_annotation[:name] %}
                    {% table_name = table_annotation[:name] %}
                  {% elsif table_annotation.args.size > 0 %}
                    {% table_name = table_annotation.args.first %}
                  {% else %}
                    {% table_name = T.name.stringify.split("::").last.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
                  {% end %}
                {% else %}
                  {% table_name = T.name.stringify.split("::").last.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
                {% end %}

                {% writable_columns = [] of String %}
                {% id_column = nil %}
                {% generated_id = false %}
                {% for ivar in T.instance_vars %}
                  {% if column_annotation = ivar.annotation(LF::Data::Column) %}
                    {% unless column_annotation[:ignore] %}
                      {% column_name = column_annotation[:name] || ivar.id.stringify %}
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
                {% if table_name.empty? || table_name.includes?("\0") %}
                  {% raise "Invalid SQL identifier for #{@type}: table name must not be empty or contain NUL" %}
                {% end %}
                {% if id_column.empty? || id_column.includes?("\0") %}
                  {% raise "Invalid SQL identifier for #{@type}: ID column name must not be empty or contain NUL" %}
                {% end %}
                {% for column in writable_columns %}
                  {% if column.empty? || column.includes?("\0") %}
                    {% raise "Invalid SQL identifier for #{@type}: column name must not be empty or contain NUL" %}
                  {% end %}
                {% end %}

                {% quoted_table = identifier_open + table_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                {% quoted_id = identifier_open + id_column.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                {% if writable_columns.empty? %}
                  {% if empty_insert_style == :default_values %}
                    {% sql = "INSERT INTO " + quoted_table + " DEFAULT VALUES" %}
                  {% else %}
                    {% sql = "INSERT INTO " + quoted_table + " () VALUES ()" %}
                  {% end %}
                {% else %}
                  {% quoted_columns = writable_columns.map do |column|
                       identifier_open + column.split(identifier_escape_from).join(identifier_escape_to) + identifier_close
                     end.join(", ") %}
                  {% placeholders = [] of String %}
                  {% for column, index in writable_columns %}
                    {% if placeholder_style == :anonymous %}
                      {% placeholders << placeholder_token %}
                    {% else %}
                      {% placeholders << placeholder_prefix + (first_position + index).stringify %}
                    {% end %}
                  {% end %}
                  {% sql = "INSERT INTO " + quoted_table + " (" + quoted_columns + ") VALUES (" + placeholders.join(", ") + ")" %}
                {% end %}

                {% if generated_id %}
                  {% generated_key_source_value = generated_key_source.resolve %}
                  {% generated_key_source_type = LF::Data::SQL::GeneratedKeySource.resolve %}
                  {% if generated_key_source_value == generated_key_source_type.constant("ReturningRow") %}
                    {% sql += " RETURNING " + quoted_id %}
                  {% end %}
                  LF::Data::SQL::InsertPlan.new(
                    {{sql}},
                    {{generated_key_source}},
                    {{id_column}}
                  )
                {% else %}
                  LF::Data::SQL::InsertPlan.new(
                    {{sql}},
                    LF::Data::SQL::GeneratedKeySource::None,
                    nil
                  )
                {% end %}
              {% end %}
            end

            def update_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
              {% begin %}
                {% policy = @type.constant("STATIC_SQL_POLICY").resolve %}
                {% identifier_open = policy.constant("IDENTIFIER_OPEN") %}
                {% identifier_close = policy.constant("IDENTIFIER_CLOSE") %}
                {% identifier_escape_from = policy.constant("IDENTIFIER_ESCAPE_FROM") %}
                {% identifier_escape_to = policy.constant("IDENTIFIER_ESCAPE_TO") %}
                {% placeholder_style = policy.constant("PLACEHOLDER_STYLE") %}

                {% if placeholder_style == :anonymous %}
                  {% placeholder_token = policy.constant("PLACEHOLDER_TOKEN") %}
                {% elsif placeholder_style == :numbered %}
                  {% placeholder_prefix = policy.constant("PLACEHOLDER_PREFIX") %}
                  {% first_position = policy.constant("PLACEHOLDER_FIRST_POSITION") %}
                {% else %}
                  {% raise "#{@type} static SQL policy has unsupported PLACEHOLDER_STYLE #{placeholder_style}" %}
                {% end %}

                {% if table_annotation = T.annotation(LF::Data::Table) %}
                  {% if table_annotation[:name] %}
                    {% table_name = table_annotation[:name] %}
                  {% elsif table_annotation.args.size > 0 %}
                    {% table_name = table_annotation.args.first %}
                  {% else %}
                    {% table_name = T.name.stringify.split("::").last.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
                  {% end %}
                {% else %}
                  {% table_name = T.name.stringify.split("::").last.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
                {% end %}

                {% assignment_columns = [] of String %}
                {% id_column = nil %}
                {% version_column = nil %}
                {% for ivar in T.instance_vars %}
                  {% if column_annotation = ivar.annotation(LF::Data::Column) %}
                    {% unless column_annotation[:ignore] %}
                      {% column_name = column_annotation[:name] || ivar.id.stringify %}
                      {% if ivar.annotation(LF::Data::Id) %}
                        {% id_column = column_name %}
                      {% elsif ivar.annotation(LF::Data::Version) %}
                        {% version_column = column_name %}
                      {% else %}
                        {% assignment_columns << column_name %}
                      {% end %}
                    {% end %}
                  {% else %}
                    {% column_name = ivar.id.stringify %}
                    {% if ivar.annotation(LF::Data::Id) %}
                      {% id_column = column_name %}
                    {% elsif ivar.annotation(LF::Data::Version) %}
                      {% version_column = column_name %}
                    {% else %}
                      {% assignment_columns << column_name %}
                    {% end %}
                  {% end %}
                {% end %}
                {% raise "Entity #{T} must define an LF::Data::Id field" unless id_column %}
                {% if assignment_columns.empty? && !version_column %}
                  {% raise "Entity #{T} has no fields available for UPDATE" %}
                {% end %}
                {% if table_name.empty? || table_name.includes?("\0") %}
                  {% raise "Invalid SQL identifier for #{@type}: table name must not be empty or contain NUL" %}
                {% end %}
                {% if id_column.empty? || id_column.includes?("\0") %}
                  {% raise "Invalid SQL identifier for #{@type}: ID column name must not be empty or contain NUL" %}
                {% end %}
                {% for column in assignment_columns %}
                  {% if column.empty? || column.includes?("\0") %}
                    {% raise "Invalid SQL identifier for #{@type}: column name must not be empty or contain NUL" %}
                  {% end %}
                {% end %}
                {% if version_column && (version_column.empty? || version_column.includes?("\0")) %}
                  {% raise "Invalid SQL identifier for #{@type}: version column name must not be empty or contain NUL" %}
                {% end %}

                {% quoted_table = identifier_open + table_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                {% quoted_id = identifier_open + id_column.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                {% assignments = [] of String %}
                {% for column, index in assignment_columns %}
                  {% quoted_column = identifier_open + column.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                  {% if placeholder_style == :anonymous %}
                    {% value_placeholder = placeholder_token %}
                  {% else %}
                    {% value_placeholder = placeholder_prefix + (first_position + index).stringify %}
                  {% end %}
                  {% assignments << quoted_column + " = " + value_placeholder %}
                {% end %}

                {% if version_column %}
                  {% quoted_version = identifier_open + version_column.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                  {% assignments << quoted_version + " = " + quoted_version + " + 1" %}
                {% end %}

                {% if placeholder_style == :anonymous %}
                  {% id_placeholder = placeholder_token %}
                  {% version_placeholder = placeholder_token %}
                {% else %}
                  {% id_position = first_position + assignment_columns.size %}
                  {% id_placeholder = placeholder_prefix + id_position.stringify %}
                  {% version_placeholder = placeholder_prefix + (id_position + 1).stringify %}
                {% end %}

                {% sql = "UPDATE " + quoted_table + " SET " + assignments.join(", ") + " WHERE " + quoted_id + " = " + id_placeholder %}
                {% if version_column %}
                  {% sql += " AND " + quoted_version + " = " + version_placeholder %}
                {% end %}
                LF::Data::SQL::StatementPlan.new({{sql}})
              {% end %}
            end

            def delete_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
              {% begin %}
                {% policy = @type.constant("STATIC_SQL_POLICY").resolve %}
                {% identifier_open = policy.constant("IDENTIFIER_OPEN") %}
                {% identifier_close = policy.constant("IDENTIFIER_CLOSE") %}
                {% identifier_escape_from = policy.constant("IDENTIFIER_ESCAPE_FROM") %}
                {% identifier_escape_to = policy.constant("IDENTIFIER_ESCAPE_TO") %}
                {% placeholder_style = policy.constant("PLACEHOLDER_STYLE") %}

                {% if placeholder_style == :anonymous %}
                  {% id_placeholder = policy.constant("PLACEHOLDER_TOKEN") %}
                  {% version_placeholder = id_placeholder %}
                {% elsif placeholder_style == :numbered %}
                  {% placeholder_prefix = policy.constant("PLACEHOLDER_PREFIX") %}
                  {% first_position = policy.constant("PLACEHOLDER_FIRST_POSITION") %}
                  {% id_placeholder = placeholder_prefix + first_position.stringify %}
                  {% version_placeholder = placeholder_prefix + (first_position + 1).stringify %}
                {% else %}
                  {% raise "#{@type} static SQL policy has unsupported PLACEHOLDER_STYLE #{placeholder_style}" %}
                {% end %}

                {% if table_annotation = T.annotation(LF::Data::Table) %}
                  {% if table_annotation[:name] %}
                    {% table_name = table_annotation[:name] %}
                  {% elsif table_annotation.args.size > 0 %}
                    {% table_name = table_annotation.args.first %}
                  {% else %}
                    {% table_name = T.name.stringify.split("::").last.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
                  {% end %}
                {% else %}
                  {% table_name = T.name.stringify.split("::").last.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase %}
                {% end %}

                {% id_column = nil %}
                {% version_column = nil %}
                {% for ivar in T.instance_vars %}
                  {% if column_annotation = ivar.annotation(LF::Data::Column) %}
                    {% unless column_annotation[:ignore] %}
                      {% column_name = column_annotation[:name] || ivar.id.stringify %}
                      {% id_column = column_name if ivar.annotation(LF::Data::Id) %}
                      {% version_column = column_name if ivar.annotation(LF::Data::Version) %}
                    {% end %}
                  {% else %}
                    {% column_name = ivar.id.stringify %}
                    {% id_column = column_name if ivar.annotation(LF::Data::Id) %}
                    {% version_column = column_name if ivar.annotation(LF::Data::Version) %}
                  {% end %}
                {% end %}
                {% raise "Entity #{T} must define an LF::Data::Id field" unless id_column %}
                {% if table_name.empty? || table_name.includes?("\0") %}
                  {% raise "Invalid SQL identifier for #{@type}: table name must not be empty or contain NUL" %}
                {% end %}
                {% if id_column.empty? || id_column.includes?("\0") %}
                  {% raise "Invalid SQL identifier for #{@type}: ID column name must not be empty or contain NUL" %}
                {% end %}
                {% if version_column && (version_column.empty? || version_column.includes?("\0")) %}
                  {% raise "Invalid SQL identifier for #{@type}: version column name must not be empty or contain NUL" %}
                {% end %}

                {% quoted_table = identifier_open + table_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                {% quoted_id = identifier_open + id_column.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                {% sql = "DELETE FROM " + quoted_table + " WHERE " + quoted_id + " = " + id_placeholder %}
                {% if version_column %}
                  {% quoted_version = identifier_open + version_column.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                  {% sql += " AND " + quoted_version + " = " + version_placeholder %}
                {% end %}
                LF::Data::SQL::StatementPlan.new({{sql}})
              {% end %}
            end
          {% end %}
        end
      end
    end
  end
end
