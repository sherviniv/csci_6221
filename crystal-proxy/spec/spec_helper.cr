require "spec"
require "../src/proxy/config"
require "../src/proxy/router"
require "../src/proxy/handler"
require "../src/proxy/health_checker"
require "../src/proxy/admin"

def build_table(yaml : String) : Proxy::RoutingTable
  Proxy::RoutingTable.build(Proxy::Config.parse(yaml))
end
