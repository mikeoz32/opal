module LF
  module Data
    enum RelationshipKind
      BelongsTo
      HasOne
      HasMany
    end

    struct RelationshipKey(Key, Checksum)
    end

    struct RelationshipSet(EntityType)
      def resolve(key : RelationshipKey(Key, Checksum)) forall Key, Checksum
        {% begin %}
          {% matching_index = nil %}
          {% matching_count = 0 %}
          {% for ivar, index in EntityType.instance_vars %}
            {% belongs_to = ivar.annotation(LF::Data::BelongsTo) %}
            {% has_one = ivar.annotation(LF::Data::HasOne) %}
            {% has_many = ivar.annotation(LF::Data::HasMany) %}
            {% if belongs_to || has_one || has_many %}
              {% relationship_key = 0_i64 %}
              {% checksum = 0_i64 %}
              {% for character in ivar.name.stringify.chars %}
                {% relationship_key = (relationship_key * 131_i64 + character.ord) % 2_147_483_647_i64 %}
                {% checksum = (checksum * 137_i64 + character.ord) % 2_147_483_647_i64 %}
              {% end %}
              {% if relationship_key == Key && checksum == Checksum %}
                {% matching_index = index %}
                {% matching_count += 1 %}
              {% end %}
            {% end %}
          {% end %}
          {% raise "Unknown relationship on #{EntityType}" unless matching_index %}
          {% raise "Compile-time relationship key collision on #{EntityType}" unless matching_count == 1 %}
          LF::Data::Relationship(EntityType, {{matching_index}}).new
        {% end %}
      end

      macro method_missing(call)
        {% relationship_key = 0_i64 %}
        {% checksum = 0_i64 %}
        {% for character in call.name.stringify.chars %}
          {% relationship_key = (relationship_key * 131_i64 + character.ord) % 2_147_483_647_i64 %}
          {% checksum = (checksum * 137_i64 + character.ord) % 2_147_483_647_i64 %}
        {% end %}
        resolve(LF::Data::RelationshipKey({{relationship_key}}, {{checksum}}).new)
      end
    end

    struct Relationship(EntityType, Index)
      def self.name : String
        {{EntityType.instance_vars[Index].name.stringify}}
      end

      def self.kind : RelationshipKind
        {% begin %}
          {% ivar = EntityType.instance_vars[Index] %}
          {% if ivar.annotation(LF::Data::BelongsTo) %}
            RelationshipKind::BelongsTo
          {% elsif ivar.annotation(LF::Data::HasOne) %}
            RelationshipKind::HasOne
          {% else %}
            RelationshipKind::HasMany
          {% end %}
        {% end %}
      end

      def self.target_type
        {% begin %}
          {% ivar = EntityType.instance_vars[Index] %}
          {% if ivar.annotation(LF::Data::HasMany) %}
            typeof(EntityType.allocate.{{ivar.name}}.first)
          {% else %}
            typeof(EntityType.allocate.{{ivar.name}}.not_nil!)
          {% end %}
        {% end %}
      end

      def self.foreign_key_property : String
        {% begin %}
          {% ivar = EntityType.instance_vars[Index] %}
          {% relationship_annotation = ivar.annotation(LF::Data::BelongsTo) ||
                                       ivar.annotation(LF::Data::HasOne) ||
                                       ivar.annotation(LF::Data::HasMany) %}
          {{relationship_annotation[:foreign_key]}}
        {% end %}
      end

      def self.cascade_persist? : Bool
        {% begin %}
          {% ivar = EntityType.instance_vars[Index] %}
          {% relationship_annotation = ivar.annotation(LF::Data::BelongsTo) ||
                                       ivar.annotation(LF::Data::HasOne) ||
                                       ivar.annotation(LF::Data::HasMany) %}
          {{relationship_annotation[:cascade_persist] || false}}
        {% end %}
      end

      def self.cascade_remove? : Bool
        {% begin %}
          {% ivar = EntityType.instance_vars[Index] %}
          {% relationship_annotation = ivar.annotation(LF::Data::BelongsTo) ||
                                       ivar.annotation(LF::Data::HasOne) ||
                                       ivar.annotation(LF::Data::HasMany) %}
          {{relationship_annotation[:cascade_remove] || false}}
        {% end %}
      end

      def self.foreign_key_table : String
        {% begin %}
          {% ivar = EntityType.instance_vars[Index] %}
          {% if ivar.annotation(LF::Data::BelongsTo) %}
            EntityType.__lf_table_name
          {% else %}
            target_type.__lf_table_name
          {% end %}
        {% end %}
      end

      def self.local_column : String
        {% begin %}
          {% relation_ivar = EntityType.instance_vars[Index] %}
          {% relationship_annotation = relation_ivar.annotation(LF::Data::BelongsTo) ||
                                       relation_ivar.annotation(LF::Data::HasOne) ||
                                       relation_ivar.annotation(LF::Data::HasMany) %}
          {% foreign_key = relationship_annotation[:foreign_key] %}
          {% if relation_ivar.annotation(LF::Data::BelongsTo) %}
            {% local_type = EntityType %}
          {% elsif relation_ivar.annotation(LF::Data::HasMany) %}
            {% local_type = relation_ivar.type.resolve.type_vars.first %}
          {% else %}
            {% local_type = relation_ivar.type.resolve.union_types.reject { |type| type == Nil }.first %}
          {% end %}
          {% local_ivar = local_type.instance_vars.find { |ivar| ivar.name.stringify == foreign_key } %}
          {% column = local_ivar.annotation(LF::Data::Column) %}
          {{(column && column[:name]) || local_ivar.name.stringify}}
        {% end %}
      end

      def self.referenced_table : String
        {% begin %}
          {% ivar = EntityType.instance_vars[Index] %}
          {% if ivar.annotation(LF::Data::BelongsTo) %}
            target_type.__lf_table_name
          {% else %}
            EntityType.__lf_table_name
          {% end %}
        {% end %}
      end

      def self.referenced_column : String
        {% begin %}
          {% ivar = EntityType.instance_vars[Index] %}
          {% if ivar.annotation(LF::Data::BelongsTo) %}
            target_type.__lf_id_column
          {% else %}
            EntityType.__lf_id_column
          {% end %}
        {% end %}
      end

      def define_foreign_key(
        table : Schema::TableBuilder,
        name : String? = nil,
      ) : Nil
        unless table.name == self.class.foreign_key_table
          raise ArgumentError.new(
            "Relationship #{EntityType}.#{self.class.name} defines a foreign key " \
            "on #{self.class.foreign_key_table.inspect}, not #{table.name.inspect}"
          )
        end

        table.foreign_key(
          self.class.local_column,
          references_table: self.class.referenced_table,
          references_column: self.class.referenced_column,
          name: name
        )
        if self.class.kind.has_one?
          table.unique(self.class.local_column)
        end
      end

      def name : String
        self.class.name
      end

      def kind : RelationshipKind
        self.class.kind
      end

      def target_type
        self.class.target_type
      end

      def foreign_key_property : String
        self.class.foreign_key_property
      end

      def cascade_persist? : Bool
        self.class.cascade_persist?
      end

      def cascade_remove? : Bool
        self.class.cascade_remove?
      end
    end

    module Schema
      class TableBuilder
        def foreign_key(
          relationship : LF::Data::Relationship(EntityType, Index),
          *,
          name : String? = nil,
        ) : Nil forall EntityType, Index
          relationship.define_foreign_key(self, name)
        end
      end
    end
  end
end
