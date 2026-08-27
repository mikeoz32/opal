require "http/server"
require "sqlite3"
require "./data_layer_example_http"

module DataLayerExample
  module HTTPCLI
    extend self

    def run : Nil
      url = ENV.fetch("OPAL_DATA_EXAMPLE_URL", "sqlite3://./data-example.db")
      host = ENV.fetch("OPAL_DATA_HTTP_HOST", "127.0.0.1")
      port = ENV.fetch("OPAL_DATA_HTTP_PORT", "8084").to_i
      store = Store.open(url)
      begin
        store.migrate
        app = Web.build_app(store)
        server = HTTP::Server.new([HTTP::LogHandler.new, app])
        Process.on_terminate { server.close }
        address = server.bind_tcp(host, port)

        puts "Listening on http://#{address}"
        puts "Routes:"
        puts "  GET    /health"
        puts "  GET    /projects"
        puts "  POST   /projects"
        puts "  GET    /projects/:project_id/tasks"
        puts "  POST   /projects/:project_id/tasks"
        puts "  PATCH  /tasks/:task_id"
        puts "  DELETE /tasks/:task_id"

        server.listen
      ensure
        store.close
      end
    end
  end
end

DataLayerExample::HTTPCLI.run
