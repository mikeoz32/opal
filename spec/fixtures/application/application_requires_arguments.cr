require "../../../src/opal"

@[LF::Application]
class InvalidApp
  def initialize(value : String)
  end
end

InvalidApp.bootstrap
