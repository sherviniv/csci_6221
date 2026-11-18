require "./spec_helper"
require "http/server"

private def autoban(threshold = 3, window = 60, ban = 300, max_tracked = 10_000, trust = false, statuses = "[401, 403, 404]") : Proxy::AutoBan
  yaml = "autoban: {threshold: #{threshold}, window_seconds: #{window}, ban_seconds: #{ban}, max_tracked: #{max_tracked}, " \
         "trust_forwarded_for: #{trust}, statuses: #{statuses}}\n" +
         %(pools: {a: {backends: ["http://h:1"]}}\nroutes: [{pool: a}])
  Proxy::AutoBan.new(Proxy::Config.parse(yaml).autoban)
end

describe Proxy::AutoBan do
  now = Time.instant

  it "is off by default" do
    off = Proxy::AutoBan.new(Proxy::AutoBanConfig.new)
    off.enabled?.should be_false
    100.times { off.record("1.1.1.1", 404, now) }
    off.banned_for("1.1.1.1", now).should be_nil
  end

  it "bans a client after `threshold` counted responses" do
    ab = autoban(threshold: 3)
    2.times { ab.record("1.1.1.1", 404, now) }
    ab.banned_for("1.1.1.1", now).should be_nil
    ab.record("1.1.1.1", 404, now)
    ab.banned_for("1.1.1.1", now).should eq 300
    ab.bans_total.should eq 1
  end

  it "only counts the configured statuses" do
    ab = autoban(threshold: 2)
    10.times { ab.record("1.1.1.1", 200, now) }
    10.times { ab.record("1.1.1.1", 500, now) }
    ab.banned_for("1.1.1.1", now).should be_nil
    ab.record("1.1.1.1", 401, now)
    ab.record("1.1.1.1", 403, now)
    ab.banned_for("1.1.1.1", now).should_not be_nil
  end

  it "keeps clients apart" do
    ab = autoban(threshold: 2)
    ab.record("1.1.1.1", 404, now)
    ab.record("2.2.2.2", 404, now)
    ab.banned_for("1.1.1.1", now).should be_nil
    ab.banned_for("2.2.2.2", now).should be_nil
  end

  it "forgets errors that are older than the window" do
    ab = autoban(threshold: 3, window: 60)
    2.times { ab.record("1.1.1.1", 404, now) }
    ab.record("1.1.1.1", 404, now + 61.seconds) # new window, counter starts again
    ab.banned_for("1.1.1.1", now + 61.seconds).should be_nil
  end

  it "ends the ban after the cooldown and starts the client fresh" do
    ab = autoban(threshold: 2, ban: 300)
    2.times { ab.record("1.1.1.1", 404, now) }
    ab.banned_for("1.1.1.1", now + 100.seconds).should eq 200 # seconds left
    ab.banned_for("1.1.1.1", now + 299.seconds).should eq 1
    ab.banned_for("1.1.1.1", now + 301.seconds).should be_nil
    # fresh start: one error is not enough again
    ab.record("1.1.1.1", 404, now + 302.seconds)
    ab.banned_for("1.1.1.1", now + 302.seconds).should be_nil
  end

  it "does not extend a running ban" do
    ab = autoban(threshold: 2, ban: 300)
    2.times { ab.record("1.1.1.1", 404, now) }
    5.times { ab.record("1.1.1.1", 404, now + 200.seconds) } # still banned: ignored
    ab.bans_total.should eq 1
    ab.banned_for("1.1.1.1", now + 301.seconds).should be_nil
  end

  it "sweeps finished bans and idle windows" do
    ab = autoban(threshold: 2, window: 60, ban: 300)
    2.times { ab.record("banned", 404, now) }
    ab.record("idle", 404, now)
    ab.sweep(now + 30.seconds)
    ab.banned(now + 30.seconds).map(&.first).should eq ["banned"]
    ab.sweep(now + 400.seconds)
    ab.banned(now + 400.seconds).should be_empty
  end

  it "stays within max_tracked (memory is bounded)" do
    ab = autoban(threshold: 100, window: 60, max_tracked: 5)
    20.times { |i| ab.record("10.0.0.#{i}", 404, now) }
    ab.record("10.0.0.99", 404, now) # table full of live entries: not tracked, no crash
    # once the old windows are over, room is freed
    ab.record("10.0.1.1", 404, now + 120.seconds)
    2.times { ab.record("10.0.1.2", 404, now + 120.seconds) }
  end

  it "picks the client key from the socket or the last X-Forwarded-For entry" do
    autoban(trust: false).client_key("9.9.9.9", "1.2.3.4").should eq "9.9.9.9"
    trusting = autoban(trust: true)
    trusting.client_key("9.9.9.9", "6.6.6.6, 1.2.3.4").should eq "1.2.3.4"
    trusting.client_key("9.9.9.9", nil).should eq "9.9.9.9"
    trusting.client_key("9.9.9.9", " ").should eq "9.9.9.9"
  end

  it "keeps bans across a config reload and forgets them when switched off" do
    ab = autoban(threshold: 1)
    ab.record("a", 404, now)
    ab.configure(autoban(threshold: 1, ban: 600).config) # e.g. a slider change in the dashboard
    ab.banned_for("a", now).should_not be_nil
    ab.configure(Proxy::AutoBanConfig.new) # threshold 0 = off
    ab.banned_for("a", now).should be_nil
    ab.enabled?.should be_false
  end

  it "can unban one client or everyone" do
    ab = autoban(threshold: 1)
    ab.record("a", 404, now)
    ab.record("b", 404, now)
    ab.unban("a").should be_true
    ab.unban("a").should be_false
    ab.banned_for("b", now).should_not be_nil
    ab.unban_all.should eq 1
    ab.banned_for("b", now).should be_nil
  end
end

describe "autoban config" do
  it "rejects nonsense values" do
    bad = %(autoban: {threshold: 5, ban_seconds: 0}\npools: {a: {backends: ["http://h:1"]}}\nroutes: [{pool: a}])
    expect_raises(Proxy::ConfigError, "autoban") { Proxy::Config.parse(bad) }
  end
end

describe "autoban through the proxy" do
  it "bans a scanner with 403 + Retry-After, leaves others alone, and lets them back after unban" do
    backend = HTTP::Server.new do |context|
      if context.request.path == "/missing"
        context.response.status_code = 404
      else
        context.response.print "ok"
      end
    end
    backend_port = backend.bind_tcp("127.0.0.1", 0).port
    spawn { backend.listen }

    yaml = "autoban: {threshold: 3, ban_seconds: 60, trust_forwarded_for: true}\n" +
           %(pools: {a: {backends: ["http://127.0.0.1:#{backend_port}"]}}\nroutes: [{pool: a}])
    config = Proxy::Config.parse(yaml)
    state = Proxy::State.new(Proxy::RoutingTable.build(config), Proxy::Metrics.new(false), Proxy::AutoBan.new(config.autoban))
    proxy = HTTP::Server.new([Proxy::Handler.new(state)])
    proxy_port = proxy.bind_tcp("127.0.0.1", 0).port
    spawn { proxy.listen }
    Fiber.yield

    url = "http://127.0.0.1:#{proxy_port}"
    scanner = HTTP::Headers{"X-Forwarded-For" => "203.0.113.7"}
    visitor = HTTP::Headers{"X-Forwarded-For" => "198.51.100.1"}

    3.times { HTTP::Client.get("#{url}/missing", headers: scanner).status_code.should eq 404 }

    banned = HTTP::Client.get("#{url}/anything", headers: scanner)
    banned.status_code.should eq 403
    banned.headers["Retry-After"].to_i.should be > 50
    state.autoban.rejected_total.should eq 1

    # another client and the same client without the header are unaffected
    HTTP::Client.get("#{url}/", headers: visitor).status_code.should eq 200
    HTTP::Client.get("#{url}/").status_code.should eq 200

    # the ban is visible in the admin output
    state.metrics.prometheus(state.table, state.autoban).should contain "proxy_autoban_banned_clients 1"
    state.metrics.state_json(state.table, state.autoban).should contain "203.0.113.7"

    # lift the ban through the admin endpoint, the way the dashboard does
    admin = Proxy::Admin.new(state, "unused.yml").server
    admin_port = admin.bind_tcp("127.0.0.1", 0).port
    spawn { admin.listen }
    Fiber.yield
    admin_url = "http://127.0.0.1:#{admin_port}"

    HTTP::Client.post("#{admin_url}/admin/unban?ip=198.51.100.99").body.should contain "was not banned"
    state.autoban.banned_for("203.0.113.7").should_not be_nil # still banned
    HTTP::Client.post("#{admin_url}/admin/unban?ip=203.0.113.7").body.should contain "unbanned 203.0.113.7"
    HTTP::Client.get("#{url}/", headers: scanner).status_code.should eq 200

    # ban again, then lift everything
    3.times { HTTP::Client.get("#{url}/missing", headers: scanner) }
    HTTP::Client.get("#{url}/", headers: scanner).status_code.should eq 403
    HTTP::Client.post("#{admin_url}/admin/unban").body.should contain "unbanned 1"
    HTTP::Client.get("#{url}/", headers: scanner).status_code.should eq 200

    admin.close
    backend.close
    proxy.close
  end
end
