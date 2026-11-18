require "./spec_helper"

describe Proxy::Balancer do
  config = Proxy::PoolConfig.new(["http://127.0.0.1:1"])
  make = ->(n : Int32) { (1..n).map { |i| Proxy::Backend.new("http://127.0.0.1:#{i}", config) } }

  it "picks the lowest active count" do
    backends = make.call(3)
    backends[0].active = 5
    backends[1].active = 1
    backends[2].active = 3
    Proxy::Balancer.pick(backends).should be(backends[1])
  end

  it "skips unhealthy backends" do
    backends = make.call(2)
    backends[0].healthy = false
    backends[1].active = 100
    Proxy::Balancer.pick(backends).should be(backends[1])
  end

  it "returns nil when all are down" do
    backends = make.call(2)
    backends.each { |b| b.healthy = false }
    Proxy::Balancer.pick(backends).should be_nil
  end

  it "breaks ties across all tied backends" do
    backends = make.call(3)
    seen = Set(String).new
    200.times { seen << Proxy::Balancer.pick(backends).not_nil!.url }
    seen.size.should eq 3
  end
end
