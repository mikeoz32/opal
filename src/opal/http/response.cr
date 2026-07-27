require "http/server"
require "json"

module LF::HTTP
  module Response
    abstract def write_to(context : ::HTTP::Server::Context) : Nil
  end

  class TextResponse
    include Response

    def initialize(@content : String)
    end

    def self.create(content : String) : Response
      new(content).as(Response)
    end

    def write_to(context : ::HTTP::Server::Context) : Nil
      context.response.content_type = "text/plain"
      context.response.print @content
    end
  end

  class JSONResponse
    include Response

    def initialize(@content : JSON::Serializable)
    end

    def self.create(content : JSON::Serializable) : Response
      new(content).as(Response)
    end

    def write_to(context : ::HTTP::Server::Context) : Nil
      context.response.content_type = "application/json"
      @content.to_json(context.response)
    end
  end
end
