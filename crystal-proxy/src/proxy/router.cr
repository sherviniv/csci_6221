require "./config"
require "./backend"
require "./balancer"

module Proxy
  # A named group of backends plus the settings shared by them.
  class Upstream
    getter name : String
    getter config : PoolConfig
    getter backends : Array(Backend)

    def initialize(@name, @config, @backends)
    end

    def pick : Backend?
      Balancer.pick(@backends)
    end
  end

  # A Struct is a value type (no heap allocation); routes are tiny and immutable.
  struct Route
    getter host : String
    getter path_prefix : String
    getter upstream : Upstream

    def initialize(@host, @path_prefix, @upstream)
    end

    # exact host = 2, "*.suffix" wildcard = 1, "*" = 0, no match = -1
    def host_rank(request_host : String) : Int32
      if host == "*"
        0
      elsif host.starts_with?("*.")
        request_host.downcase.ends_with?(host[1..].downcase) ? 1 : -1
      else
        host.compare(request_host, case_insensitive: true) == 0 ? 2 : -1
      end
    end
  end

  # Immutable routing table. A reload builds a brand new one and swaps the
  # reference, so request fibers never see a half-updated table.
  class RoutingTable
    getter routes : Array(Route)
    getter upstreams : Hash(String, Upstream)
    getter? stopped = false

    def initialize(@routes, @upstreams)
    end

    def self.build(config : Config, previous : RoutingTable? = nil) : RoutingTable
      upstreams = {} of String => Upstream
      config.pools.each do |name, pool|
        old_backends = previous.try(&.upstreams[name]?).try(&.backends)
        backends = pool.backends.map do |url|
          backend = Backend.new(url, pool)
          # keep health knowledge across reloads (no 502 blip when scaling)
          if old = old_backends.try(&.find { |b| b.url == url })
            backend.healthy = old.healthy?
          end
          backend
        end
        upstreams[name] = Upstream.new(name, pool, backends)
      end
      routes = config.routes.map { |r| Route.new(r.host, r.path_prefix, upstreams[r.pool]) }
      new(routes, upstreams)
    end

    def stop : Nil
      @stopped = true
    end

    # Exact host beats wildcard host, then the longest path prefix wins.
    def match(host : String, path : String) : Route?
      best = nil
      best_rank = -1
      best_len = -1
      @routes.each do |route|
        rank = route.host_rank(host)
        next if rank < 0 || !path.starts_with?(route.path_prefix)
        len = route.path_prefix.size
        if rank > best_rank || (rank == best_rank && len > best_len)
          best = route
          best_rank = rank
          best_len = len
        end
      end
      best
    end
  end
end
