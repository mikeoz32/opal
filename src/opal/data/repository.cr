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

      def first? : Bool
        number == 1_i64
      end

      def last? : Bool
        !has_next?
      end

      def has_previous? : Bool
        number > 1_i64
      end

      def has_next? : Bool
        number < total_pages
      end
    end

    class Repository(EntityType, IDType)
      getter manager : EntityManager

      def initialize(@manager : EntityManager)
      end

      def find(id : IDType) : EntityType?
        manager.find(EntityType, id)
      end

      def persist(entity : EntityType) : Nil
        manager.persist(entity)
      end

      def remove(entity : EntityType) : Nil
        manager.remove(entity)
      end

      def delete(id : IDType) : Bool
        manager.delete(EntityType, id)
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

      def update
        manager.update(EntityType)
      end

      def delete_all
        manager.delete(EntityType)
      end

      def page(
        selection : Query::SelectQuery(
          EntityType,
          Predicate,
          Orders,
          Query::NoLimit,
          Query::NoOffset,
        ),
        *,
        number : Int,
        size : Int,
      ) : Page(EntityType) forall Predicate, Orders
        {% if Orders == Query::NoOrdering %}
          {% raise "#{EntityType} repository pagination requires at least one order_by" %}
        {% end %}
        unless selection.manager.same?(manager)
          raise RepositoryQueryOwnershipError.new(EntityType.name)
        end

        page_number, normalized_size, offset = page_window(number, size)
        total_items = selection.count
        items = selection
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
        order_by : Ordering,
      ) : Page(EntityType) forall Ordering
        page(
          query.order_by(order_by),
          number: number,
          size: page_size
        )
      end

      def page(
        number : Int,
        page_size : Int,
        *,
        where predicate : Predicate,
        order_by : Ordering,
      ) : Page(EntityType) forall Predicate, Ordering
        page(
          query.where(predicate).order_by(order_by),
          number: number,
          size: page_size
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
