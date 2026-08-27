require "./data_layer_example_application"

module DataLayerExample
  module ApplicationCLI
    extend self

    def run : Nil
      DataLayerApplication.run do |runtime|
        runtime.resolve(DataLayerExample::DataStoreService)
        extension = LF::HTTP::AutoConfig.install(runtime)
        Process.on_terminate { extension.stop }

        address = extension.bind
        puts "Listening on http://#{address}"
        puts "Routes: Application + DI + controller discovery"
        extension.listen
      end
    end
  end
end

@[LF::Application]
@[LF::AutoConfig::HTTP]
class DataLayerApplication
end

DataLayerExample::ApplicationCLI.run
