module LF
  module Data
    module Query
      struct RenderedQuery
        getter sql : String
        getter arguments : Array(DB::Any)

        def initialize(@sql, @arguments)
        end
      end
    end
  end
end
