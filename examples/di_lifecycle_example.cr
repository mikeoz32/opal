require "../src/opal"

class RequestResource
  include LF::DI::Initializable
  include LF::DI::Disposable

  @@next_id = 0

  getter id : Int32

  def initialize
    @@next_id += 1
    @id = @@next_id
  end

  def after_properties_set : Nil
    puts "init request resource ##{id}"
  end

  def destroy : Nil
    puts "destroy request resource ##{id}"
  end
end

class RootResource
  include LF::DI::Initializable
  include LF::DI::Disposable

  def after_properties_set : Nil
    puts "init root resource"
  end

  def destroy : Nil
    puts "destroy root resource"
  end
end

root = LF::DI::AnnotationApplicationContext.new

root.add_bean(name: "root_resource", type: RootResource) do |_ctx|
  RootResource.new
end

root.add_bean(name: "request_resource", scope: "request", type: RequestResource) do |_ctx|
  RequestResource.new
end

puts "Resolving singleton from root"
root.get_bean("root_resource", RootResource)

puts "Entering request scope"
request = root.enter_scope("request")
request.get_bean("request_resource", RequestResource)
request.get_bean("request_resource", RequestResource)

puts "Exiting request scope"
request.exit

puts "Shutting down root context"
root.shutdown
