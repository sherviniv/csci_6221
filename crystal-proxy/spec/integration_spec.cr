require "./spec_helper"
require "http/server"

# Starts a tiny backend on a random port; returns {server, port}.
def start_backend(&handler : HTTP::Server::Context ->) : {HTTP::Server, Int32}
  server = HTTP::Server.new(&handler)
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  Fiber.yield
  {server, address.port}
end

def start_proxy(yaml : String) : {HTTP::Server, Int32, Proxy::State}
  config = Proxy::Config.parse(yaml)
  metrics = Proxy::Metrics.new(false)
  table = Proxy::RoutingTable.build(config)
  state = Proxy::State.new(table, metrics)
  server = HTTP::Server.new([Proxy::Handler.new(state)])
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  Fiber.yield
  {server, address.port, state}
end

def pool_yaml(ports : Array(Int32), extra = "") : String
  urls = ports.map { |p| %("http://127.0.0.1:#{p}") }.join(", ")
  "pools: {a: {backends: [#{urls}], connect_timeout_ms: 300, read_timeout_ms: 500#{extra}}}\nroutes: [{pool: a}]"
end

describe "proxy integration" do
  it "forwards X-Forwarded-* and strips hop-by-hop headers" do
    seen = HTTP::Headers.new
    backend, bport = start_backend do |ctx|
      seen = ctx.request.headers.dup
      ctx.response.headers["Keep-Alive"] = "timeout=5"
      ctx.response.headers["X-Custom"] = "yes"
      ctx.response.print "hello"
    end
    proxy, pport, _ = start_proxy(pool_yaml([bport]))

    headers = HTTP::Headers{"Connection" => "X-Secret", "X-Secret" => "s", "X-Forwarded-For" => "1.2.3.4"}
    response = HTTP::Client.get("http://127.0.0.1:#{pport}/x", headers: headers)
    response.body.should eq "hello"
    response.headers["X-Custom"].should eq "yes"
    response.headers["Keep-Alive"]?.should be_nil
    seen["X-Secret"]?.should be_nil
    seen["X-Forwarded-For"].should eq "1.2.3.4, 127.0.0.1"
    seen["X-Forwarded-Proto"].should eq "http"
    seen["X-Forwarded-Host"].should start_with "127.0.0.1"
    backend.close
    proxy.close
  end

  it "streams a 100 MB response and a 20 MB request" do
    backend, bport = start_backend do |ctx|
      if ctx.request.method == "POST"
        count = 0_i64
        buffer = Bytes.new(64 * 1024)
        body = ctx.request.body.not_nil!
        while (n = body.read(buffer)) > 0
          count += n
        end
        ctx.response.print count
      else
        total = 100 * 1024 * 1024
        ctx.response.content_length = total
        chunk = Bytes.new(64 * 1024)
        (total // chunk.size).times { ctx.response.write(chunk) }
      end
    end
    proxy, pport, _ = start_proxy(pool_yaml([bport], ", read_timeout_ms: 20000"))

    received = 0_i64
    HTTP::Client.get("http://127.0.0.1:#{pport}/") do |response|
      buffer = Bytes.new(64 * 1024)
      while (n = response.body_io.read(buffer)) > 0
        received += n
      end
    end
    received.should eq 100 * 1024 * 1024

    upload = IO::Sized.new(IO::Memory.new(Bytes.new(20 * 1024 * 1024)), 20 * 1024 * 1024)
    HTTP::Client.post("http://127.0.0.1:#{pport}/", headers: HTTP::Headers{"Content-Length" => (20 * 1024 * 1024).to_s}, body: upload).body.should eq (20 * 1024 * 1024).to_s
    backend.close
    proxy.close
  end

  it "returns 502 when the backend is down" do
    backend, bport = start_backend { |ctx| ctx.response.print "x" }
    backend.close
    proxy, pport, _ = start_proxy(pool_yaml([bport]))
    HTTP::Client.get("http://127.0.0.1:#{pport}/").status_code.should eq 502
    proxy.close
  end

  it "returns 504 when the backend is too slow" do
    backend, bport = start_backend do |ctx|
      sleep 2.seconds
      ctx.response.print "late"
    end
    proxy, pport, _ = start_proxy(pool_yaml([bport]))
    HTTP::Client.get("http://127.0.0.1:#{pport}/").status_code.should eq 504
    backend.close
    proxy.close
  end

  it "returns 404 when no route matches and 502 when all backends are unhealthy" do
    yaml = "pools: {a: {backends: [\"http://127.0.0.1:1\"]}}\nroutes: [{pool: a, path_prefix: \"/api\"}]"
    proxy, pport, state = start_proxy(yaml)
    HTTP::Client.get("http://127.0.0.1:#{pport}/other").status_code.should eq 404
    state.table.upstreams["a"].backends.each { |b| b.healthy = false }
    HTTP::Client.get("http://127.0.0.1:#{pport}/api").status_code.should eq 502
    proxy.close
  end

  it "health checks eject a dead backend so traffic fails over to the live one" do
    live, lport = start_backend { |ctx| ctx.response.print "live" }
    dead, dport = start_backend { |ctx| ctx.response.print "dead" }
    dead.close
    yaml = pool_yaml([dport, lport], ", health_path: \"/h\", health_interval_ms: 50, unhealthy_after: 2")
    proxy, pport, state = start_proxy(yaml)
    Proxy::HealthChecker.start(state.table)
    sleep 1.second
    statuses = 10.times.map { HTTP::Client.get("http://127.0.0.1:#{pport}/").status_code }.to_a
    statuses.uniq.should eq [200]
    state.table.stop
    live.close
    proxy.close
  end
end
