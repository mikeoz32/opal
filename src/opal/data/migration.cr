module LF
  module Data
    class SchemaEditor
    end

    abstract class Migration
      abstract def version : Int64
      abstract def name : String
      abstract def up(schema : SchemaEditor) : Nil
    end
  end
end
