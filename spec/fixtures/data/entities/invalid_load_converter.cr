require "../../../../src/opal/data"

module InvalidLoadConverter
  def self.load(result : DB::ResultSet) : Int32
    1
  end

  def self.dump(value : String) : String
    value
  end
end

def exercise_invalid_load(result : DB::ResultSet)
  LF::Data::Converter.load(result, InvalidLoadConverter, String)
end

result = uninitialized DB::ResultSet
exercise_invalid_load(result)
