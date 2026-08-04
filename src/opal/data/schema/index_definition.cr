module LF
  module Data
    module Schema
      record IndexDefinition,
        name : String,
        columns : Array(String),
        unique : Bool do
        def unique? : Bool
          unique
        end
      end
    end
  end
end
