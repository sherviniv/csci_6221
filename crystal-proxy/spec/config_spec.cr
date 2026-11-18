require "./spec_helper"

describe Proxy::Config do
  it "loads the example config" do
    config = Proxy::Config.load("config/proxy.yml")
    config.pools.keys.should eq ["api", "web"]
    config.pools["api"].read_timeout_ms.should eq 10_000
  end

  it "applies defaults" do
    config = Proxy::Config.parse(%(pools: {a: {backends: ["http://h:1"]}}\nroutes: [{pool: a}]))
    config.routes[0].host.should eq "*"
    config.pools["a"].unhealthy_after.should eq 3
  end

  {
    "unknown pool"   => { %(pools: {a: {backends: ["http://h:1"]}}\nroutes: [{pool: nope}]), "unknown pool 'nope'" },
    "empty backends" => { %(pools: {a: {backends: []}}\nroutes: [{pool: a}]), "has no backends" },
    "bad url"        => { %(pools: {a: {backends: ["ftp//x"]}}\nroutes: [{pool: a}]), "bad backend URL" },
    "bad prefix"     => { %(pools: {a: {backends: ["http://h:1"]}}\nroutes: [{pool: a, path_prefix: "x"}]), "must start with '/'" },
    "broken yaml"    => {"pools: [", "invalid YAML"},
    "missing pools"  => {"routes: []", "invalid YAML"},
  }.each do |name, (yaml, message)|
    it "rejects #{name}" do
      expect_raises(Proxy::ConfigError, message) { Proxy::Config.parse(yaml) }
    end
  end
end
