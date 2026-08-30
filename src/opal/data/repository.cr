module LF
  module Data
    struct Page(EntityType)
      getter items : Array(EntityType)
      getter number : Int64
      getter page_size : Int64
      getter total_items : Int64

      def initialize(
        @items : Array(EntityType),
        @number : Int64,
        @page_size : Int64,
        @total_items : Int64,
      )
      end

      def total_pages : Int64
        quotient = total_items // page_size
        total_items % page_size == 0 ? quotient : quotient + 1_i64
      end

      def empty? : Bool
        items.empty?
      end
    end

    class Repository(EntityType, IDType)
      getter manager : EntityManager

      def initialize(@manager : EntityManager)
      end

      def find(id : IDType) : EntityType?
        manager.find(EntityType, id)
      end

      def find_by(predicate : Predicate) : EntityType? forall Predicate
        query.where(predicate).first?
      end

      def exists? : Bool
        query.exists?
      end

      def exists?(predicate : Predicate) : Bool forall Predicate
        query.where(predicate).exists?
      end

      def count : Int64
        query.count
      end

      def count(predicate : Predicate) : Int64 forall Predicate
        query.where(predicate).count
      end

      def query
        manager.query(EntityType)
      end

      def dynamic_query
        manager.dynamic_query(EntityType)
      end

      def page(
        number : Int,
        page_size : Int,
        *,
        order_by : Ordering,
      ) : Page(EntityType) forall Ordering
        page_number, normalized_size, offset = page_window(number, page_size)
        total_items = count
        items = query
          .order_by(order_by)
          .limit(normalized_size)
          .offset(offset)
          .to_a
        Page(EntityType).new(
          items,
          page_number,
          normalized_size,
          total_items
        )
      end

      def page(
        number : Int,
        page_size : Int,
        *,
        where predicate : Predicate,
        order_by : Ordering,
      ) : Page(EntityType) forall Predicate, Ordering
        page_number, normalized_size, offset = page_window(number, page_size)
        filtered = query.where(predicate)
        total_items = filtered.count
        items = filtered
          .order_by(order_by)
          .limit(normalized_size)
          .offset(offset)
          .to_a
        Page(EntityType).new(
          items,
          page_number,
          normalized_size,
          total_items
        )
      end

      private def page_window(
        number : Int,
        page_size : Int,
      ) : {Int64, Int64, Int64}
        normalized_number = number.to_i64
        normalized_size = page_size.to_i64
        if normalized_number < 1_i64
          raise InvalidQueryError.new(:page, normalized_number)
        end
        if normalized_size < 1_i64
          raise InvalidQueryError.new(:page_size, normalized_size)
        end

        offset = (normalized_number.to_i128 - 1_i128) * normalized_size
        if offset > Int64::MAX
          raise InvalidQueryError.new(:page, normalized_number)
        end
        {normalized_number, normalized_size, offset.to_i64}
      end
    end

    class EntityManager
      def repository(entity : T.class) forall T
        {% begin %}
          {% id_ivar = T.instance_vars.find { |ivar| ivar.annotation(LF::Data::Id) } %}
          {% id_annotation = id_ivar.annotation(LF::Data::Id) %}
          {% id_type = id_ivar.type.resolve %}
          {% if id_annotation[:generated] %}
            {% lookup_id_type = id_type.union_types.reject { |type| type == Nil }.first %}
          {% else %}
            {% lookup_id_type = id_type %}
          {% end %}
          LF::Data::Repository(T, {{lookup_id_type}}).new(self)
        {% end %}
      end
    end
  end
end
