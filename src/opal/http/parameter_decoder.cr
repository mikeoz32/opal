require "uuid"
require "./errors"

module LF::HTTP::ParameterDecoder
  def self.decode(values, key : String, type : Int32.class) : Int32
    value(values, key).to_i
  rescue ArgumentError
    invalid(key, type)
  end

  def self.decode(values, key : String, type : Int64.class) : Int64
    value(values, key).to_i64
  rescue ArgumentError
    invalid(key, type)
  end

  def self.decode(values, key : String, type : Float32.class) : Float32
    value(values, key).to_f32
  rescue ArgumentError
    invalid(key, type)
  end

  def self.decode(values, key : String, type : Float64.class) : Float64
    value(values, key).to_f64
  rescue ArgumentError
    invalid(key, type)
  end

  def self.decode(values, key : String, type : Bool.class) : Bool
    case value(values, key).downcase
    when "true", "1", "yes"
      true
    when "false", "0", "no"
      false
    else
      invalid(key, type)
    end
  end

  def self.decode(values, key : String, type : UUID.class) : UUID
    UUID.new(value(values, key))
  rescue ArgumentError
    invalid(key, type)
  end

  def self.decode(values, key : String, type : String.class) : String
    value(values, key)
  end

  private def self.value(values, key : String) : String
    raise BadRequest.new("Missing required parameter '#{key}'") unless values.has_key?(key)
    values[key].to_s
  end

  private def self.invalid(key : String, type : T.class) : NoReturn forall T
    raise BadRequest.new("Invalid value for parameter '#{key}': expected #{T}")
  end
end
