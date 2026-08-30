module LF
  module Data
    enum DialectCapability
      LastInsertId
      ReturningRow
      TransactionalDDL
      MigrationLock
      AddColumn
      RenameColumn
      ForeignKeyDDL
    end
  end
end
