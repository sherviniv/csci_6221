require "http/client"
require "log"
require "./router"

module Proxy
  # One lightweight fiber per backend. Fibers are cheap (a few KB), so
  # hundreds of backends cost almost nothing. A fiber exits by itself once
  # its routing table has been replaced by a reload.
  module HealthChecker
    def self.start(table : RoutingTable) : Nil
      table.upstreams.each_value do |upstream|
        upstream.backends.each do |backend|
          spawn(name: "health #{backend.url}") { loop_for(table, upstream, backend) }
        end
      end
    end

    private def self.loop_for(table, upstream, backend) : Nil
      config = upstream.config
      until table.stopped?
        probe(backend, config) ? mark_ok(backend, config) : mark_fail(backend, config)
        sleep config.health_interval_ms.milliseconds
      end
    end

    private def self.probe(backend : Backend, config : PoolConfig) : Bool
      client = HTTP::Client.new(backend.uri.host.not_nil!, backend.uri.port || 80)
      client.connect_timeout = config.connect_timeout_ms.milliseconds
      client.read_timeout = config.connect_timeout_ms.milliseconds
      begin
        response = client.get(config.health_path)
        (200..399).includes?(response.status_code)
      ensure
        client.close
      end
    rescue IO::Error | Socket::Error
      false
    end

    private def self.mark_ok(backend : Backend, config : PoolConfig) : Nil
      backend.consecutive_fail = 0
      backend.consecutive_ok += 1
      if !backend.healthy? && backend.consecutive_ok >= config.healthy_after
        backend.healthy = true
        Log.info { "backend UP   #{backend.url}" }
      end
    end

    private def self.mark_fail(backend : Backend, config : PoolConfig) : Nil
      backend.consecutive_ok = 0
      backend.consecutive_fail += 1
      if backend.healthy? && backend.consecutive_fail >= config.unhealthy_after
        backend.healthy = false
        Log.warn { "backend DOWN #{backend.url}" }
      end
    end
  end
end
