module LF
  module Data
    module Internal
      class OperationQueue
        def initialize
          @entries = [] of TrackedEntity?
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
          end
          entry.operation = operation
        end

        def cancel(entry : TrackedEntity) : Nil
          return unless entry.operation

          entry.operation = nil
          index = @head
          while index < @entries.size
            if queued = @entries[index]
              if queued.same?(entry)
                @entries[index] = nil
                break
              end
            end
            index += 1
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

        def complete(entry : TrackedEntity) : Nil
          entry.operation = nil
          entry.sequence = nil
          @entries[@head] = nil
          @head += 1
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
