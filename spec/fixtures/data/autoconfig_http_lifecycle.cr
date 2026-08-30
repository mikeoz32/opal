require "../../../src/opal"
require "../../../src/opal/autoconfig/data"
require "../../../src/opal/autoconfig/http"
require "sqlite3"
require "http/client"

@[LF::DI::Service]
class DataHTTPShutdownProbe
  include LF::DI::Disposable

  @@destroyed = false

  def self.destroyed? : Bool
    @@destroyed
  end

  def destroy : Nil
    @@destroyed = true
  end
end

class DataHTTPShutdownController
  include LF::HTTP::Controller

  @@started = Channel(Nil).new
  @@release = Channel(Nil).new

  def self.wait_until_started : Nil
    @@started.receive
  end

  def self.release : Nil
    @@release.send(nil)
  end

  def initialize(@data_source : LF::Data::DataSource)
  end

  @[LF::HTTP::Controller::Get("/data-autoconfig/drain")]
  def show : String
    @@started.send(nil)
    @@release.receive
    raise "DataSource closed during request" if @data_source.closed?

    @data_source.transaction do |manager|
      manager.connection.scalar("SELECT 1")
    end.to_s
  end
end

@[LF::Application]
@[LF::AutoConfig::Data]
@[LF::AutoConfig::HTTP]
class DataHTTPShutdownApplication
end

runtime = DataHTTPShutdownApplication.bootstrap
source = runtime.resolve(LF::Data::DataSource)
runtime.resolve(DataHTTPShutdownProbe)
http_extension = LF::HTTP::AutoConfig.install(runtime)
address = http_extension.bind

spawn { http_extension.listen }
response = Channel(HTTP::Client::Response).new
spawn do
  response.send(
    HTTP::Client.get(
      "http://127.0.0.1:#{address.port}/data-autoconfig/drain"
    )
  )
end
DataHTTPShutdownController.wait_until_started

shutdown = Channel(Exception?).new
spawn do
  begin
    runtime.shutdown
    shutdown.send(nil)
  rescue error : Exception
    shutdown.send(error)
  end
end
sleep 10.milliseconds

raise "DataSource closed before the active request drained" if source.closed?
raise "DI singleton destroyed before the active request drained" if DataHTTPShutdownProbe.destroyed?

DataHTTPShutdownController.release
raise "active request could not query DataSource" unless response.receive.body == "1"
if shutdown_error = shutdown.receive
  raise shutdown_error
end
raise "HTTP extension did not stop" unless http_extension.stopped?
raise "DataSource remained open after shutdown" unless source.closed?
raise "DI singleton was not destroyed" unless DataHTTPShutdownProbe.destroyed?
