require "option_parser"
require "log"
require "./proxy/config"
require "./proxy/router"
require "./proxy/metrics"
require "./proxy/handler"
require "./proxy/health_checker"
require "./proxy/admin"

config_path : String = "config/proxy.yml"
listen_override : String? = nil
admin_override : String? = nil

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal-proxy [options]"
  parser.on("-c PATH", "--config=PATH", "YAML config (default config/proxy.yml)") { |v| config_path = v }
  parser.on("--listen=ADDR", "Override listen address") { |v| listen_override = v }
  parser.on("--admin=ADDR", "Override metrics_listen address") { |v| admin_override = v }
  parser.on("-h", "--help", "Show help") do
    puts parser
    exit
  end
end

def split_address(address : String) : {String, Int32}
  host, _, port = address.rpartition(':')
  {host.empty? ? "0.0.0.0" : host, port.to_i}
end

# copies: variables captured by the OptionParser closures lose nil-narrowing
listen_addr = listen_override
admin_addr = admin_override

config = begin
  Proxy::Config.load(config_path)
rescue ex : Proxy::ConfigError
  STDERR.puts "config error: #{ex.message}"
  exit 1
end

metrics = Proxy::Metrics.new(config.access_log)
table = Proxy::RoutingTable.build(config)
Proxy::HealthChecker.start(table)
autoban = Proxy::AutoBan.new(config.autoban)
autoban.start_sweeper
state = Proxy::State.new(table, metrics, autoban)
admin = Proxy::Admin.new(state, config_path)

server = HTTP::Server.new([Proxy::Handler.new(state)])
host, port = split_address(listen_addr || config.listen)
server.bind_tcp(host, port)

admin_server = admin.server
admin_host, admin_port = split_address(admin_addr || config.metrics_listen)
admin_server.bind_tcp(admin_host, admin_port)
spawn(name: "admin") { admin_server.listen }

Log.info { "crystal-proxy listening on #{host}:#{port}, admin on #{admin_host}:#{admin_port}" }
server.listen
