require "opal"

router = LF::HTTP::Router.new
router.get("/") { |context, _params| context.response.print "Opal is running" }

server = HTTP::Server.new(router)
server.bind_tcp(8080)
server.listen
