require "yaml"
require "uri"

module Proxy
  class ConfigError < Exception
  end

  # YAML::Serializable maps YAML keys to typed instance variables at compile
  # time. A missing required key or a wrong type raises YAML::ParseException.
  class PoolConfig
    include YAML::Serializable

    getter backends : Array(String)
    getter health_path : String = "/"
    getter health_interval_ms : Int32 = 2000
    getter unhealthy_after : Int32 = 3
    getter healthy_after : Int32 = 2
    getter connect_timeout_ms : Int32 = 1000
    getter read_timeout_ms : Int32 = 10_000
    getter max_idle_connections : Int32 = 64
    getter idle_timeout_ms : Int32 = 30_000

    def initialize(@backends, @health_path = "/")
    end
  end

  class RouteConfig
    include YAML::Serializable

    getter host : String = "*"
    getter path_prefix : String = "/"
    getter pool : String

    def initialize(@pool, @host = "*", @path_prefix = "/")
    end
  end

  # Temporary IP bans for clients that keep receiving error responses.
  # Off unless threshold > 0.
  class AutoBanConfig
    include YAML::Serializable

    getter threshold : Int32 = 0                     # counted responses within the window that cause a ban (0 = off)
    getter window_seconds : Int32 = 60               # length of the counting window
    getter ban_seconds : Int32 = 300                 # cooldown: how long the client stays banned
    getter statuses : Array(Int32) = [401, 403, 404] # response statuses that count against a client
    getter max_tracked : Int32 = 10_000              # memory cap on remembered clients
    # Identify the client by the LAST X-Forwarded-For entry instead of the socket address.
    # Only enable behind a trusted proxy/load balancer, otherwise clients can fake their address.
    getter trust_forwarded_for : Bool = false

    def initialize
    end
  end

  class Config
    include YAML::Serializable

    getter listen : String = "0.0.0.0:8080"
    getter metrics_listen : String = "127.0.0.1:9090"
    getter access_log : Bool = true
    getter autoban : AutoBanConfig = AutoBanConfig.new
    getter pools : Hash(String, PoolConfig)
    getter routes : Array(RouteConfig)

    def self.load(path : String) : Config
      parse(File.read(path))
    rescue ex : File::Error
      raise ConfigError.new("cannot read config #{path}: #{ex.message}")
    end

    def self.parse(yaml : String) : Config
      config = from_yaml(yaml)
      config.validate
      config
    rescue ex : YAML::ParseException
      raise ConfigError.new("invalid YAML: #{ex.message}")
    end

    def validate : Nil
      raise ConfigError.new("no pools defined") if pools.empty?
      raise ConfigError.new("no routes defined") if routes.empty?
      if autoban.threshold < 0 || autoban.window_seconds < 1 || autoban.ban_seconds < 1 || autoban.max_tracked < 1
        raise ConfigError.new("autoban: threshold must be >= 0 and window_seconds, ban_seconds, max_tracked must be >= 1")
      end
      pools.each do |name, pool|
        raise ConfigError.new("pool '#{name}' has no backends") if pool.backends.empty?
        pool.backends.each do |url|
          uri = URI.parse(url)
          host = uri.host
          unless uri.scheme == "http" && host && !host.empty?
            raise ConfigError.new("pool '#{name}': bad backend URL '#{url}' (expected http://host:port)")
          end
        end
      end
      routes.each do |route|
        unless pools.has_key?(route.pool)
          raise ConfigError.new("route for '#{route.host}#{route.path_prefix}' references unknown pool '#{route.pool}'")
        end
        unless route.path_prefix.starts_with?('/')
          raise ConfigError.new("route path_prefix '#{route.path_prefix}' must start with '/'")
        end
      end
    end
  end
end
