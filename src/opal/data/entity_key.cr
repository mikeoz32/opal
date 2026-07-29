module LF
  module Data
    module Internal
      record EntityKey,
        entity_type : String,
        id : DB::Any
    end
  end
end
