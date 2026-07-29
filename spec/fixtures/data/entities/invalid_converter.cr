require "../../../../src/opal/data"

class InvalidStoredValue
end

module InvalidDumpConverter
  def self.load(result : DB::ResultSet) : String
    result.read(String)
  end

  def self.dump(value : String) : InvalidStoredValue
    InvalidStoredValue.new
  end
end

value : DB::Any = LF::Data::Converter.dump("invalid", InvalidDumpConverter)
