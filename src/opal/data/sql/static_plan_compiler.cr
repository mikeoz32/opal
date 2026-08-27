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
            def update_query_plan(entity : T.class, shape : S.class) : LF::Data::SQL::StatementPlan forall T, S
              __lf_compile_bulk_plan(
                T,
                S,
                typeof(S.__lf_predicate_tokens),
                LF::Data::Query::BulkUpdate
              )
            end

            def delete_query_plan(entity : T.class, shape : S.class) : LF::Data::SQL::StatementPlan forall T, S
              __lf_compile_bulk_plan(
                T,
                S,
                typeof(S.__lf_predicate_tokens),
                LF::Data::Query::BulkDelete
              )
            end

            def select_plan(entity : T.class, shape : S.class) : LF::Data::SQL::StatementPlan forall T, S
              __lf_compile_select_plan(
                T,
                S,
                typeof(S.__lf_predicate_tokens),
                typeof(S.__lf_order_tokens)
              )
            end

            def find_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
              {% begin %}
                {% policy_owner = @type %}
                {% unless policy_owner.has_constant?("STATIC_SQL_POLICY") %}
                  {% policy_owner = @type.ancestors.find(&.has_constant?("STATIC_SQL_POLICY")) %}
                {% end %}
                {% raise "#{@type} has no inherited STATIC_SQL_POLICY" unless policy_owner %}
                {% policy_reference = policy_owner.constant("STATIC_SQL_POLICY") %}
                {% if policy_reference.is_a?(Path) &&
                        policy_reference.names.size == 1 &&
                        policy_owner.has_constant?(policy_reference.stringify) %}
                  {% policy = policy_owner.constant(policy_reference.stringify).resolve %}
                {% else %}
                  {% policy = policy_reference.resolve %}
                {% end %}
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
                {% policy_owner = @type %}
                {% unless policy_owner.has_constant?("STATIC_SQL_POLICY") %}
                  {% policy_owner = @type.ancestors.find(&.has_constant?("STATIC_SQL_POLICY")) %}
                {% end %}
                {% raise "#{@type} has no inherited STATIC_SQL_POLICY" unless policy_owner %}
                {% policy_reference = policy_owner.constant("STATIC_SQL_POLICY") %}
                {% if policy_reference.is_a?(Path) &&
                        policy_reference.names.size == 1 &&
                        policy_owner.has_constant?(policy_reference.stringify) %}
                  {% policy = policy_owner.constant(policy_reference.stringify).resolve %}
                {% else %}
                  {% policy = policy_reference.resolve %}
                {% end %}
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
                {% policy_owner = @type %}
                {% unless policy_owner.has_constant?("STATIC_SQL_POLICY") %}
                  {% policy_owner = @type.ancestors.find(&.has_constant?("STATIC_SQL_POLICY")) %}
                {% end %}
                {% raise "#{@type} has no inherited STATIC_SQL_POLICY" unless policy_owner %}
                {% policy_reference = policy_owner.constant("STATIC_SQL_POLICY") %}
                {% if policy_reference.is_a?(Path) &&
                        policy_reference.names.size == 1 &&
                        policy_owner.has_constant?(policy_reference.stringify) %}
                  {% policy = policy_owner.constant(policy_reference.stringify).resolve %}
                {% else %}
                  {% policy = policy_reference.resolve %}
                {% end %}
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
                {% policy_owner = @type %}
                {% unless policy_owner.has_constant?("STATIC_SQL_POLICY") %}
                  {% policy_owner = @type.ancestors.find(&.has_constant?("STATIC_SQL_POLICY")) %}
                {% end %}
                {% raise "#{@type} has no inherited STATIC_SQL_POLICY" unless policy_owner %}
                {% policy_reference = policy_owner.constant("STATIC_SQL_POLICY") %}
                {% if policy_reference.is_a?(Path) &&
                        policy_reference.names.size == 1 &&
                        policy_owner.has_constant?(policy_reference.stringify) %}
                  {% policy = policy_owner.constant(policy_reference.stringify).resolve %}
                {% else %}
                  {% policy = policy_reference.resolve %}
                {% end %}
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

            private def __lf_compile_select_plan(
              entity : T.class,
              shape : S.class,
              predicate_tokens : P.class,
              order_tokens : O.class,
            ) : LF::Data::SQL::StatementPlan forall T, S, P, O
              {% begin %}
                {% policy_owner = @type %}
                {% unless policy_owner.has_constant?("STATIC_SQL_POLICY") %}
                  {% policy_owner = @type.ancestors.find(&.has_constant?("STATIC_SQL_POLICY")) %}
                {% end %}
                {% raise "#{@type} has no inherited STATIC_SQL_POLICY" unless policy_owner %}
                {% policy_reference = policy_owner.constant("STATIC_SQL_POLICY") %}
                {% if policy_reference.is_a?(Path) &&
                        policy_reference.names.size == 1 &&
                        policy_owner.has_constant?(policy_reference.stringify) %}
                  {% policy = policy_owner.constant(policy_reference.stringify).resolve %}
                {% else %}
                  {% policy = policy_reference.resolve %}
                {% end %}
                {% identifier_open = policy.constant("IDENTIFIER_OPEN") %}
                {% identifier_close = policy.constant("IDENTIFIER_CLOSE") %}
                {% identifier_escape_from = policy.constant("IDENTIFIER_ESCAPE_FROM") %}
                {% identifier_escape_to = policy.constant("IDENTIFIER_ESCAPE_TO") %}
                {% placeholder_style = policy.constant("PLACEHOLDER_STYLE") %}
                {% query_shape = S.type_vars[0] %}
                {% limit_state = query_shape.type_vars[3] %}
                {% offset_state = query_shape.type_vars[4] %}
                {% terminal_name = S.name.stringify.split("(").first.split("::").last %}

                {% if placeholder_style == :anonymous %}
                  {% placeholder_token = policy.constant("PLACEHOLDER_TOKEN") %}
                {% else %}
                  {% placeholder_prefix = policy.constant("PLACEHOLDER_PREFIX") %}
                  {% first_position = policy.constant("PLACEHOLDER_FIRST_POSITION") %}
                {% end %}
                {% placeholder_position = 0 %}

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
                {% for ivar in T.instance_vars %}
                  {% column_annotation = ivar.annotation(LF::Data::Column) %}
                  {% unless column_annotation && column_annotation[:ignore] %}
                    {% column_name = (column_annotation && column_annotation[:name]) || ivar.name.stringify %}
                    {% selected_columns << identifier_open + column_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                  {% end %}
                {% end %}
                {% quoted_table = identifier_open + table_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}

                {% if terminal_name == "Count" %}
                  {% sql = "SELECT COUNT(*) FROM " + quoted_table %}
                {% elsif terminal_name == "Exists" %}
                  {% sql = "SELECT 1 FROM " + quoted_table %}
                {% else %}
                  {% sql = "SELECT " + selected_columns.join(", ") + " FROM " + quoted_table %}
                {% end %}

                {% unless P.type_vars.empty? %}
                  {% sql += " WHERE " %}
                  {% for token in P.type_vars %}
                    {% token_name = token.name.stringify.split("(").first.split("::").last %}
                    {% if token_name == "OpenParen" %}
                      {% sql += "(" %}
                    {% elsif token_name == "CloseParen" %}
                      {% sql += ")" %}
                    {% elsif token_name == "And" %}
                      {% sql += " AND " %}
                    {% elsif token_name == "Or" %}
                      {% sql += " OR " %}
                    {% elsif token_name == "Not" %}
                      {% sql += "NOT " %}
                    {% elsif token_name == "Leaf" %}
                      {% expression = token.type_vars[0] %}
                      {% expression_name = expression.name.stringify.split("(").first.split("::").last %}
                      {% field = expression.type_vars[0] %}
                      {% field_entity = field.type_vars[0] %}
                      {% unless field_entity == T %}
                        {% raise "#{field_entity} field belongs to #{field_entity}, not query entity #{T}" %}
                      {% end %}
                      {% field_index = field.type_vars[2] %}
                      {% ivar = T.instance_vars[field_index] %}
                      {% column_annotation = ivar.annotation(LF::Data::Column) %}
                      {% column_name = (column_annotation && column_annotation[:name]) || ivar.name.stringify %}
                      {% quoted_column = identifier_open + column_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}

                      {% if expression_name == "IsNil" %}
                        {% sql += quoted_column + " IS NULL" %}
                      {% elsif expression_name == "IsNotNil" %}
                        {% sql += quoted_column + " IS NOT NULL" %}
                      {% elsif expression_name == "In" %}
                        {% value_count = expression.type_vars[1].type_vars.size %}
                        {% if value_count == 0 %}
                          {% sql += "0 = 1" %}
                        {% else %}
                          {% placeholders = [] of String %}
                          {% for _ in 0...value_count %}
                            {% if placeholder_style == :anonymous %}
                              {% placeholders << placeholder_token %}
                            {% else %}
                              {% placeholders << placeholder_prefix + (first_position + placeholder_position).stringify %}
                            {% end %}
                            {% placeholder_position += 1 %}
                          {% end %}
                          {% sql += quoted_column + " IN (" + placeholders.join(", ") + ")" %}
                        {% end %}
                      {% else %}
                        {% operator = if expression_name == "Eq"
                                        "="
                                      elsif expression_name == "Ne"
                                        "<>"
                                      elsif expression_name == "Lt"
                                        "<"
                                      elsif expression_name == "Lte"
                                        "<="
                                      elsif expression_name == "Gt"
                                        ">"
                                      elsif expression_name == "Gte"
                                        ">="
                                      elsif expression_name == "Like"
                                        "LIKE"
                                      else
                                        raise "Unsupported static predicate #{expression}"
                                      end %}
                        {% if placeholder_style == :anonymous %}
                          {% placeholder = placeholder_token %}
                        {% else %}
                          {% placeholder = placeholder_prefix + (first_position + placeholder_position).stringify %}
                        {% end %}
                        {% placeholder_position += 1 %}
                        {% sql += quoted_column + " " + operator + " " + placeholder %}
                      {% end %}
                    {% else %}
                      {% raise "Unsupported static predicate token #{token}" %}
                    {% end %}
                  {% end %}
                {% end %}

                {% if terminal_name != "Count" && terminal_name != "Exists" && !O.type_vars.empty? %}
                  {% order_clauses = [] of String %}
                  {% for token in O.type_vars %}
                    {% ordering = token.type_vars[0] %}
                    {% field = ordering.type_vars[0] %}
                    {% field_entity = field.type_vars[0] %}
                    {% unless field_entity == T %}
                      {% raise "#{field_entity} field belongs to #{field_entity}, not query entity #{T}" %}
                    {% end %}
                    {% direction = ordering.type_vars[1] %}
                    {% field_index = field.type_vars[2] %}
                    {% ivar = T.instance_vars[field_index] %}
                    {% column_annotation = ivar.annotation(LF::Data::Column) %}
                    {% column_name = (column_annotation && column_annotation[:name]) || ivar.name.stringify %}
                    {% quoted_column = identifier_open + column_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                    {% direction_name = direction.name.stringify.split("::").last.upcase %}
                    {% order_clauses << quoted_column + " " + direction_name %}
                  {% end %}
                  {% sql += " ORDER BY " + order_clauses.join(", ") %}
                {% end %}

                {% if terminal_name == "Exists" %}
                  {% sql += " LIMIT 1" %}
                {% elsif terminal_name == "First" %}
                  {% sql += " LIMIT 1" %}
                  {% if offset_state.name.stringify.split("::").last == "WithOffset" %}
                    {% if placeholder_style == :anonymous %}
                      {% offset_placeholder = placeholder_token %}
                    {% else %}
                      {% offset_placeholder = placeholder_prefix + (first_position + placeholder_position).stringify %}
                    {% end %}
                    {% sql += " OFFSET " + offset_placeholder %}
                  {% end %}
                {% elsif terminal_name == "Rows" %}
                  {% has_limit = limit_state.name.stringify.split("::").last == "WithLimit" %}
                  {% has_offset = offset_state.name.stringify.split("::").last == "WithOffset" %}
                  {% if has_limit %}
                    {% if placeholder_style == :anonymous %}
                      {% limit_placeholder = placeholder_token %}
                    {% else %}
                      {% limit_placeholder = placeholder_prefix + (first_position + placeholder_position).stringify %}
                    {% end %}
                    {% placeholder_position += 1 %}
                    {% sql += " LIMIT " + limit_placeholder %}
                  {% end %}
                  {% if has_offset %}
                    {% if placeholder_style == :anonymous %}
                      {% offset_placeholder = placeholder_token %}
                    {% else %}
                      {% offset_placeholder = placeholder_prefix + (first_position + placeholder_position).stringify %}
                    {% end %}
                    {% if has_limit %}
                      {% sql += " OFFSET " + offset_placeholder %}
                    {% elsif policy.has_constant?("OFFSET_ONLY_PREFIX") %}
                      {% sql += " " + policy.constant("OFFSET_ONLY_PREFIX") + offset_placeholder %}
                    {% else %}
                      {% sql += " OFFSET " + offset_placeholder %}
                    {% end %}
                  {% end %}
                {% end %}

                LF::Data::SQL::StatementPlan.new({{sql}})
              {% end %}
            end

            private def __lf_compile_bulk_plan(
              entity : T.class,
              shape : S.class,
              predicate_tokens : P.class,
              operation : M.class,
            ) : LF::Data::SQL::StatementPlan forall T, S, P, M
              {% begin %}
                {% policy_owner = @type %}
                {% unless policy_owner.has_constant?("STATIC_SQL_POLICY") %}
                  {% policy_owner = @type.ancestors.find(&.has_constant?("STATIC_SQL_POLICY")) %}
                {% end %}
                {% raise "#{@type} has no inherited STATIC_SQL_POLICY" unless policy_owner %}
                {% policy_reference = policy_owner.constant("STATIC_SQL_POLICY") %}
                {% if policy_reference.is_a?(Path) &&
                        policy_reference.names.size == 1 &&
                        policy_owner.has_constant?(policy_reference.stringify) %}
                  {% policy = policy_owner.constant(policy_reference.stringify).resolve %}
                {% else %}
                  {% policy = policy_reference.resolve %}
                {% end %}
                {% identifier_open = policy.constant("IDENTIFIER_OPEN") %}
                {% identifier_close = policy.constant("IDENTIFIER_CLOSE") %}
                {% identifier_escape_from = policy.constant("IDENTIFIER_ESCAPE_FROM") %}
                {% identifier_escape_to = policy.constant("IDENTIFIER_ESCAPE_TO") %}
                {% placeholder_style = policy.constant("PLACEHOLDER_STYLE") %}

                {% if placeholder_style == :anonymous %}
                  {% placeholder_token = policy.constant("PLACEHOLDER_TOKEN") %}
                {% else %}
                  {% placeholder_prefix = policy.constant("PLACEHOLDER_PREFIX") %}
                  {% first_position = policy.constant("PLACEHOLDER_FIRST_POSITION") %}
                {% end %}
                {% placeholder_position = 0 %}

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
                {% quoted_table = identifier_open + table_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}

                {% if M == LF::Data::Query::BulkUpdate %}
                  {% assignment_fields = S.type_vars[1] %}
                  {% raise "#{T} bulk UPDATE requires at least one SET clause" if assignment_fields.type_vars.empty? %}
                  {% assignments = [] of String %}
                  {% version_column = nil %}
                  {% for ivar in T.instance_vars %}
                    {% if column_annotation = ivar.annotation(LF::Data::Column) %}
                      {% unless column_annotation[:ignore] %}
                        {% if ivar.annotation(LF::Data::Version) %}
                          {% version_column = column_annotation[:name] || ivar.name.stringify %}
                        {% end %}
                      {% end %}
                    {% elsif ivar.annotation(LF::Data::Version) %}
                      {% version_column = ivar.name.stringify %}
                    {% end %}
                  {% end %}
                  {% for field in assignment_fields.type_vars %}
                    {% field_entity = field.type_vars[0] %}
                    {% unless field_entity == T %}
                      {% raise "#{field_entity} field belongs to #{field_entity}, not update entity #{T}" %}
                    {% end %}
                    {% field_index = field.type_vars[2] %}
                    {% ivar = T.instance_vars[field_index] %}
                    {% column_annotation = ivar.annotation(LF::Data::Column) %}
                    {% column_name = (column_annotation && column_annotation[:name]) || ivar.name.stringify %}
                    {% quoted_column = identifier_open + column_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                    {% if placeholder_style == :anonymous %}
                      {% placeholder = placeholder_token %}
                    {% else %}
                      {% placeholder = placeholder_prefix + (first_position + placeholder_position).stringify %}
                    {% end %}
                    {% placeholder_position += 1 %}
                    {% assignments << quoted_column + " = " + placeholder %}
                  {% end %}
                  {% if version_column %}
                    {% quoted_version = identifier_open + version_column.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}
                    {% assignments << quoted_version + " = " + quoted_version + " + 1" %}
                  {% end %}
                  {% sql = "UPDATE " + quoted_table + " SET " + assignments.join(", ") %}
                {% else %}
                  {% sql = "DELETE FROM " + quoted_table %}
                {% end %}

                {% unless P.type_vars.empty? %}
                  {% sql += " WHERE " %}
                  {% for token in P.type_vars %}
                    {% token_name = token.name.stringify.split("(").first.split("::").last %}
                    {% if token_name == "OpenParen" %}
                      {% sql += "(" %}
                    {% elsif token_name == "CloseParen" %}
                      {% sql += ")" %}
                    {% elsif token_name == "And" %}
                      {% sql += " AND " %}
                    {% elsif token_name == "Or" %}
                      {% sql += " OR " %}
                    {% elsif token_name == "Not" %}
                      {% sql += "NOT " %}
                    {% elsif token_name == "Leaf" %}
                      {% expression = token.type_vars[0] %}
                      {% expression_name = expression.name.stringify.split("(").first.split("::").last %}
                      {% field = expression.type_vars[0] %}
                      {% field_entity = field.type_vars[0] %}
                      {% unless field_entity == T %}
                        {% raise "#{field_entity} field belongs to #{field_entity}, not bulk entity #{T}" %}
                      {% end %}
                      {% field_index = field.type_vars[2] %}
                      {% ivar = T.instance_vars[field_index] %}
                      {% column_annotation = ivar.annotation(LF::Data::Column) %}
                      {% column_name = (column_annotation && column_annotation[:name]) || ivar.name.stringify %}
                      {% quoted_column = identifier_open + column_name.split(identifier_escape_from).join(identifier_escape_to) + identifier_close %}

                      {% if expression_name == "IsNil" %}
                        {% sql += quoted_column + " IS NULL" %}
                      {% elsif expression_name == "IsNotNil" %}
                        {% sql += quoted_column + " IS NOT NULL" %}
                      {% elsif expression_name == "In" %}
                        {% value_count = expression.type_vars[1].type_vars.size %}
                        {% if value_count == 0 %}
                          {% sql += "0 = 1" %}
                        {% else %}
                          {% placeholders = [] of String %}
                          {% for _ in 0...value_count %}
                            {% if placeholder_style == :anonymous %}
                              {% placeholders << placeholder_token %}
                            {% else %}
                              {% placeholders << placeholder_prefix + (first_position + placeholder_position).stringify %}
                            {% end %}
                            {% placeholder_position += 1 %}
                          {% end %}
                          {% sql += quoted_column + " IN (" + placeholders.join(", ") + ")" %}
                        {% end %}
                      {% else %}
                        {% operator = if expression_name == "Eq"
                                        "="
                                      elsif expression_name == "Ne"
                                        "<>"
                                      elsif expression_name == "Lt"
                                        "<"
                                      elsif expression_name == "Lte"
                                        "<="
                                      elsif expression_name == "Gt"
                                        ">"
                                      elsif expression_name == "Gte"
                                        ">="
                                      elsif expression_name == "Like"
                                        "LIKE"
                                      else
                                        raise "Unsupported static bulk predicate #{expression}"
                                      end %}
                        {% if placeholder_style == :anonymous %}
                          {% placeholder = placeholder_token %}
                        {% else %}
                          {% placeholder = placeholder_prefix + (first_position + placeholder_position).stringify %}
                        {% end %}
                        {% placeholder_position += 1 %}
                        {% sql += quoted_column + " " + operator + " " + placeholder %}
                      {% end %}
                    {% else %}
                      {% raise "Unsupported static bulk predicate token #{token}" %}
                    {% end %}
                  {% end %}
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
