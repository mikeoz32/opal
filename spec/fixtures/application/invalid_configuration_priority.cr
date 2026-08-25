require "../../../src/opal"

@[LF::ApplicationConfiguration(priority: "high")]
class InvalidPriorityConfiguration
end

@[LF::Application]
class ValidPriorityApp
end

ValidPriorityApp.bootstrap
