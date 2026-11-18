require "uri"
require "./config"
require "./connection_pool"

module Proxy
  class Backend
    getter url : String
    getter uri : URI
    getter conn_pool : ConnectionPool

    property active = 0      # requests in flight (the least-connections key)
    property? healthy = true # false = skipped by the balancer

    # Only touched by this backend's health-check fiber.
    property consecutive_ok = 0
    property consecutive_fail = 0

    def initialize(@url : String, config : PoolConfig)
      @uri = URI.parse(url)
      @conn_pool = ConnectionPool.new(@uri, config)
    end
  end
end
