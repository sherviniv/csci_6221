require "./backend"

module Proxy
  module Balancer
    def self.pick(backends : Array(Backend)) : Backend?
      healthy = backends.select(&.healthy?)
      return nil if healthy.empty?
      lowest = healthy.min_of(&.active)
      healthy.select { |b| b.active == lowest }.sample
    end
  end
end
