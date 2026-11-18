require "./spec_helper"

YAML_ROUTES = <<-Y
pools:
  api: {backends: ["http://127.0.0.1:1"]}
  web: {backends: ["http://127.0.0.1:2"]}
  deep: {backends: ["http://127.0.0.1:3"]}
routes:
  - {host: "api.example.local", path_prefix: "/", pool: api}
  - {host: "*", path_prefix: "/static", pool: web}
  - {host: "*", path_prefix: "/static/deep", pool: deep}
  - {host: "*.cdn.local", path_prefix: "/", pool: web}
Y

describe Proxy::RoutingTable do
  table = build_table(YAML_ROUTES)

  it "matches an exact host" do
    table.match("api.example.local", "/x").not_nil!.upstream.name.should eq "api"
  end

  it "falls back to the wildcard host" do
    table.match("other.local", "/static/a.css").not_nil!.upstream.name.should eq "web"
  end

  it "longest path prefix wins" do
    table.match("other.local", "/static/deep/x").not_nil!.upstream.name.should eq "deep"
  end

  it "exact host beats wildcard even with a shorter prefix" do
    table.match("api.example.local", "/static/a").not_nil!.upstream.name.should eq "api"
  end

  it "supports *.suffix hosts" do
    table.match("img.cdn.local", "/a").not_nil!.upstream.name.should eq "web"
  end

  it "returns nil when nothing matches" do
    table.match("other.local", "/nope").should be_nil
  end
end
