module LF
  module Data
    module Internal
      class OperationQueue
        def initialize
          @entries = [] of TrackedEntity?
          @positions = {} of UInt64 => Int32
          @head = 0
        end

        def schedule(
          entry : TrackedEntity,
          operation : EntityOperation,
          sequence : Int64,
        ) : Nil
          unless entry.operation
            entry.sequence = sequence
            @entries << entry
            @positions[entry.reference.object_id] = @entries.size - 1
          end
          entry.operation = operation
        end

        def cancel(entry : TrackedEntity) : Nil
          return unless entry.operation

          entry.operation = nil
          if index = @positions.delete(entry.reference.object_id)
            @entries[index] = nil
          end
          advance_head
        end

        def clear : Nil
          @entries.each do |entry|
            if queued = entry
              queued.operation = nil
              queued.sequence = nil
            end
          end
          @entries.clear
          @positions.clear
          @head = 0
        end

        def each(& : TrackedEntity ->) : Nil
          index = @head
          while index < @entries.size
            if entry = @entries[index]
              yield entry
            end
            index += 1
          end
        end

        def first? : TrackedEntity?
          advance_head
          @entries[@head]?
        end

        def to_a : Array(TrackedEntity)
          entries = [] of TrackedEntity
          each { |entry| entries << entry }
          entries
        end

        def pending_for?(entity_name : String) : Bool
          each do |entry|
            return true if entry.entity_name == entity_name
          end
          false
        end

        def complete(entry : TrackedEntity) : Nil
          entry.operation = nil
          entry.sequence = nil
          if index = @positions.delete(entry.reference.object_id)
            @entries[index] = nil
          end
          advance_head
        end

        def diagnostics : Array({EntityOperation, UInt64, Int64})
          diagnostics = [] of {EntityOperation, UInt64, Int64}
          each do |entry|
            if (operation = entry.operation) && (sequence = entry.sequence)
              diagnostics << {operation, entry.reference.object_id, sequence}
            end
          end
          diagnostics
        end

        private def advance_head : Nil
          while @head < @entries.size && @entries[@head].nil?
            @head += 1
          end
          return unless @head == @entries.size

          @entries.clear
          @head = 0
        end
      end
    end
  end
end
