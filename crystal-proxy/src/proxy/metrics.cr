require "json"
require "./router"
require "./autoban"

module Proxy
  # One finished request.
  struct Event
    getter time : Time
    getter client : String
    getter method : String
    getter host : String
    getter path : String
    getter status : Int32
    getter bytes : Int64
    getter backend : String
    getter duration_ms : Float64

    def initialize(@time, @client, @method, @host, @path, @status, @bytes, @backend, @duration_ms)
    end
  end

  # Plain counters, updated by #record after every request.
  class Metrics
    BUCKETS_MS = [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]

    getter total = 0_i64
    getter classes = Hash(String, Int64).new(0_i64) # "2xx" => count
    getter hist = Array(Int64).new(BUCKETS_MS.size + 1, 0_i64)
    getter duration_sum_ms = 0.0
    getter bytes_total = 0_i64
    getter per_backend = Hash(String, {Int64, Int64}).new({0_i64, 0_i64}) # url => {requests, errors}
    getter recent = Deque(Event).new
    getter started_at = Time.utc

    def initialize(@access_log : Bool = true)
    end

    def record(event : Event) : Nil
      @total += 1
      @classes["#{event.status // 100}xx"] += 1
      @bytes_total += event.bytes
      @duration_sum_ms += event.duration_ms
      index = BUCKETS_MS.index { |limit| event.duration_ms <= limit } || BUCKETS_MS.size
      @hist[index] += 1
      unless event.backend.empty?
        requests, errors = @per_backend[event.backend]
        @per_backend[event.backend] = {requests + 1, errors + (event.status >= 500 ? 1 : 0)}
      end
      @recent.push(event)
      @recent.shift if @recent.size > 40
      if @access_log
        puts "#{event.time.to_rfc3339(fraction_digits: 3)} #{event.client} #{event.method} #{event.host} #{event.path} #{event.status} #{event.bytes} #{event.backend.empty? ? "-" : event.backend} #{event.duration_ms.round(2)}ms"
      end
    end

    def prometheus(table : RoutingTable, autoban : AutoBan) : String
      String.build do |io|
        io << "# TYPE proxy_requests_total counter\nproxy_requests_total #{@total}\n"
        io << "# TYPE proxy_autoban_bans_total counter\nproxy_autoban_bans_total #{autoban.bans_total}\n"
        io << "# TYPE proxy_autoban_rejected_total counter\nproxy_autoban_rejected_total #{autoban.rejected_total}\n"
        io << "# TYPE proxy_autoban_banned_clients gauge\nproxy_autoban_banned_clients #{autoban.banned.size}\n"
        io << "# TYPE proxy_responses_total counter\n"
        {"1xx", "2xx", "3xx", "4xx", "5xx"}.each do |klass|
          io << %(proxy_responses_total{class="#{klass}"} #{@classes[klass]}\n)
        end
        io << "# TYPE proxy_backend_healthy gauge\n"
        io << "# TYPE proxy_backend_active_connections gauge\n"
        table.upstreams.each_value do |upstream|
          upstream.backends.each do |b|
            labels = %(pool="#{upstream.name}",backend="#{b.url}")
            io << "proxy_backend_healthy{#{labels}} #{b.healthy? ? 1 : 0}\n"
            io << "proxy_backend_active_connections{#{labels}} #{b.active}\n"
          end
        end
        io << "# TYPE proxy_request_duration_ms histogram\n"
        cumulative = 0_i64
        BUCKETS_MS.each_with_index do |limit, i|
          cumulative += @hist[i]
          io << %(proxy_request_duration_ms_bucket{le="#{limit}"} #{cumulative}\n)
        end
        io << %(proxy_request_duration_ms_bucket{le="+Inf"} #{@total}\n)
        io << "proxy_request_duration_ms_sum #{@duration_sum_ms.round(3)}\nproxy_request_duration_ms_count #{@total}\n"
      end
    end

    # Everything the dashboard needs in one JSON document.
    def state_json(table : RoutingTable, autoban : AutoBan) : String
      JSON.build do |json|
        json.object do
          json.field "uptime_s", (Time.utc - @started_at).total_seconds.round(1)
          json.field "total", @total
          json.field "bytes", @bytes_total
          json.field "avg_ms", (@total > 0 ? (@duration_sum_ms / @total).round(3) : 0.0)
          json.field "classes" do
            json.object { %w(1xx 2xx 3xx 4xx 5xx).each { |k| json.field k, @classes[k] } }
          end
          json.field "autoban" do
            json.object do
              json.field "enabled", autoban.enabled?
              json.field "threshold", autoban.config.threshold
              json.field "window_seconds", autoban.config.window_seconds
              json.field "ban_seconds", autoban.config.ban_seconds
              json.field "bans_total", autoban.bans_total
              json.field "rejected_total", autoban.rejected_total
              json.field "banned" do
                json.array do
                  autoban.banned.each do |client, seconds_left|
                    json.object do
                      json.field "client", client
                      json.field "seconds_left", seconds_left
                    end
                  end
                end
              end
            end
          end
          json.field "buckets_ms", BUCKETS_MS
          json.field "histogram", @hist
          json.field "pools" do
            json.array do
              table.upstreams.each_value do |upstream|
                json.object do
                  json.field "name", upstream.name
                  json.field "backends" do
                    json.array do
                      upstream.backends.each do |b|
                        requests, errors = @per_backend[b.url]
                        json.object do
                          json.field "url", b.url
                          json.field "healthy", b.healthy?
                          json.field "active", b.active
                          json.field "idle_connections", b.conn_pool.idle_count
                          json.field "requests", requests
                          json.field "errors", errors
                        end
                      end
                    end
                  end
                end
              end
            end
          end
          json.field "recent" do
            json.array do
              @recent.reverse_each do |e|
                json.object do
                  json.field "t", e.time.to_unix_ms
                  json.field "method", e.method
                  json.field "path", e.path
                  json.field "status", e.status
                  json.field "backend", e.backend
                  json.field "ms", e.duration_ms.round(2)
                end
              end
            end
          end
        end
      end
    end
  end
end
