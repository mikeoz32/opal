require "../../../src/opal"

module LF::AutoConfig
  annotation NotExtensionFixture
  end
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::NotExtensionFixture)]
class NotAnApplicationExtension
end

@[LF::Application]
class NotExtensionApp
end
