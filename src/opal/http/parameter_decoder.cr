require "uuid"
require "./errors"

module LF::HTTP::ParameterDecoder
  def self.decode(value : String, key : String, type : Int32.class) : Int32
    value.to_i
  rescue ArgumentError
    invalid(key, type)
  end

  def self.decode(value : String, key : String, type : Int64.class) : Int64
    value.to_i64
  rescue ArgumentError
    invalid(key, type)
  end

  def self.decode(value : String, key : String, type : Float32.class) : Float32
    value.to_f32
  rescue ArgumentError
    invalid(key, type)
  end

  def self.decode(value : String, key : String, type : Float64.class) : Float64
    value.to_f64
  rescue ArgumentError
    invalid(key, type)
  end

  def self.decode(value : String, key : String, type : Bool.class) : Bool
    case value.downcase
    when "true", "1", "yes"
      true
    when "false", "0", "no"
      false
    else
      invalid(key, type)
    end
  end

  def self.decode(value : String, key : String, type : UUID.class) : UUID
    UUID.new(value)
  rescue ArgumentError
    invalid(key, type)
  end

  def self.decode(value : String, key : String, type : String.class) : String
    value
  end

  def self.decode(values, key : String, type : Int32.class) : Int32
    decode(value(values, key), key, type)
  end

  def self.decode(values, key : String, type : Int64.class) : Int64
    decode(value(values, key), key, type)
  end

  def self.decode(values, key : String, type : Float32.class) : Float32
    decode(value(values, key), key, type)
  end

  def self.decode(values, key : String, type : Float64.class) : Float64
    decode(value(values, key), key, type)
  end

  def self.decode(values, key : String, type : Bool.class) : Bool
    decode(value(values, key), key, type)
  end

  def self.decode(values, key : String, type : UUID.class) : UUID
    decode(value(values, key), key, type)
  end

  def self.decode(values, key : String, type : String.class) : String
    decode(value(values, key), key, type)
  end

  private def self.value(values, key : String) : String
    raise BadRequest.new("Missing required parameter '#{key}'") unless values.has_key?(key)
    values[key].to_s
  end

  private def self.invalid(key : String, type : T.class) : NoReturn forall T
    raise BadRequest.new("Invalid value for parameter '#{key}': expected #{T}")
  end
end
