module LF
  module Data
    module SQL
      enum GeneratedKeySource
        None
        LastInsertId
        ReturningRow
      end

      record InsertPlan,
        sql : String,
        generated_key_source : GeneratedKeySource,
        generated_column : String?
    end
  end
end
