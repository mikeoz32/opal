module LF
  module Data
    enum DialectCapability
      LastInsertId
      ReturningRow
      TransactionalDDL
      MigrationLock
      SchemaInspection
      AddColumn
      RenameColumn
      ForeignKeyDDL
    end
  end
end
