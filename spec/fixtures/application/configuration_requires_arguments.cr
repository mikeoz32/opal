require "../../../src/opal"

@[LF::ApplicationConfiguration]
class InvalidConfiguration
  def initialize(value : String)
  end
end

@[LF::Application]
class ValidApp
end

ValidApp.bootstrap
