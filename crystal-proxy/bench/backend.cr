# Tiny benchmark backend. DELAY_MS makes every request (except /health) slow,
# which is how we simulate one sick server.
require "http/server"

delay = (ENV["DELAY_MS"]? || "0").to_i

server = HTTP::Server.new do |context|
  sleep delay.milliseconds if delay > 0 && context.request.path != "/health"
  context.response.content_type = "text/plain"
  context.response.print "ok\n"
end
server.bind_tcp("0.0.0.0", 80)
server.listen
