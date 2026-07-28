require "yaml"

module LF
  class ConfigService
    DEFAULT_PATH = "config/application.yml"

    class Error < Exception
    end

    class LoadError < Error
      getter path : String

      def initialize(@path : String, message : String)
        super(message)
      end
    end

    class MissingKeyError < Error
      getter key : String

      def initialize(@key : String)
        super("Missing configuration key: #{key}")
      end
    end

    @root : YAML::Any

    def initialize
      if path = ENV["OPAL_CONFIG"]?
        @root = load(path, explicit: true)
      elsif File.exists?(DEFAULT_PATH)
        @root = load(DEFAULT_PATH, explicit: false)
      else
        @root = YAML.parse("{}")
      end
    end

    def initialize(path : String)
      @root = load(path, explicit: true)
    end

    def get(key : String) : YAML::Any
      value = find(key) || raise MissingKeyError.new(key)
      YAML.parse(value.to_yaml)
    end

    def get(key : String, default : T) : T forall T
      value = find(key)
      return default unless value
      T.from_yaml(value.to_yaml)
    end

    def section(key : String) : YAML::Any
      value = get(key)
      value.as_h
      value
    end

    private def find(key : String) : YAML::Any?
      current = @root

      key.split('.').each do |segment|
        current = current[segment]?
        return nil unless current
      end

      current
    rescue KeyError | TypeCastError
      nil
    end

    private def load(path : String, *, explicit : Bool) : YAML::Any
      unless File.exists?(path)
        if explicit
          raise LoadError.new(path, "Configuration file does not exist: #{path}")
        end
        return YAML.parse("{}")
      end

      YAML.parse(File.read(path))
    rescue error : LoadError
      raise error
    rescue error : Exception
      reason = error.message || error.class.to_s
      raise LoadError.new(path, "Failed to load configuration from #{path}: #{reason}")
    end
  end
end
