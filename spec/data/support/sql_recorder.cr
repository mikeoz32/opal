require "db"

module LF::DataSpecSupport
  record SQLStatement, sql : String, args : Array(DB::Any)

  class SQLRecorder
    getter statements : Array(SQLStatement)

    def initialize
      @statements = [] of SQLStatement
    end

    def record(sql : String) : Nil
      @statements << SQLStatement.new(sql, [] of DB::Any)
    end

    def record(sql : String, *args : DB::Any) : Nil
      values = [] of DB::Any
      args.each { |arg| values << arg }
      @statements << SQLStatement.new(sql, values)
    end

    def clear : Nil
      @statements.clear
    end
  end
end
