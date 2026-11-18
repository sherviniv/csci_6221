require "http/server"
require "log"
require "./handler"
require "./health_checker"

module Proxy
  # Small second HTTP server on metrics_listen. Never expose it publicly.
  #   GET  /metrics       Prometheus text
  #   GET  /api/state     JSON for the dashboard
  #   POST /admin/reload  re-read the config file
  #   POST /admin/unban   lift one ban (?ip=...) or, without ip, all bans
  class Admin
    def initialize(@state : State, @config_path : String)
    end

    # Invalid config => keep serving with the old one and report why.
    def reload : String?
      config = Config.load(@config_path)
      table = RoutingTable.build(config, @state.table)
      HealthChecker.start(table)
      @state.autoban.configure(config.autoban)
      @state.swap(table)
      Log.info { "config reloaded from #{@config_path}" }
      nil
    rescue ex : ConfigError
      Log.error { "reload rejected, keeping old config: #{ex.message}" }
      ex.message
    end

    def server : HTTP::Server
      HTTP::Server.new do |context|
        response = context.response
        response.headers["Access-Control-Allow-Origin"] = "*"
        case {context.request.method, context.request.path}
        when {"GET", "/metrics"}
          response.content_type = "text/plain; version=0.0.4"
          response.print @state.metrics.prometheus(@state.table, @state.autoban)
        when {"GET", "/api/state"}
          response.content_type = "application/json"
          response.print @state.metrics.state_json(@state.table, @state.autoban)
        when {"POST", "/admin/reload"}
          if error = reload
            response.status_code = 400
            response.content_type = "text/plain"
            response.print error
          else
            response.print "reloaded\n"
          end
        when {"POST", "/admin/unban"}
          if ip = context.request.query_params["ip"]?
            response.print(@state.autoban.unban(ip) ? "unbanned #{ip}\n" : "#{ip} was not banned\n")
          else
            response.print "unbanned #{@state.autoban.unban_all}\n"
          end
        else
          response.status_code = 404
          response.print "not found\n"
        end
      end
    end
  end
end
