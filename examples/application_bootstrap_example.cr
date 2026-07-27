require "../src/opal"

class Clock
  def now : Time
    Time.utc
  end
end

@[LF::ApplicationConfiguration(priority: 10)]
class Infrastructure
  @[LF::DI::Bean]
  def clock : Clock
    Clock.new
  end
end

@[LF::DI::Service]
class GreetingService
  def initialize(@clock : Clock)
  end

  def greeting : String
    "Application started at #{@clock.now}"
  end
end

@[LF::Application]
class ExampleApplication
end

ExampleApplication.run do |application|
  puts application.resolve(GreetingService).greeting
end
