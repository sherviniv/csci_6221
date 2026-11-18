require "http/client"
require "./config"

module Proxy
  class ConnectionPool
    def initialize(@uri : URI, @config : PoolConfig)
      @idle = [] of {HTTP::Client, Time::Instant}
    end

    # Reuse the most recently used idle connection, or open a new one.
    def checkout : HTTP::Client
      while entry = @idle.pop?
        client, since = entry
        return client if Time.instant - since < @config.idle_timeout_ms.milliseconds
        client.close # idle too long, the backend may have dropped it
      end
      build_client
    end

    # Call only after the response body was fully read.
    def checkin(client : HTTP::Client) : Nil
      if @idle.size < @config.max_idle_connections
        @idle << {client, Time.instant}
      else
        client.close
      end
    end

    def idle_count : Int32
      @idle.size
    end

    private def build_client : HTTP::Client
      client = HTTP::Client.new(@uri.host.not_nil!, @uri.port || 80)
      client.connect_timeout = @config.connect_timeout_ms.milliseconds
      client.read_timeout = @config.read_timeout_ms.milliseconds
      client.write_timeout = @config.read_timeout_ms.milliseconds
      client.compress = false # we only forward bytes, never decode them
      client
    end
  end
end
