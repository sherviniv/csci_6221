require "http/server"
require "./router"
require "./metrics"
require "./autoban"

module Proxy
  # The shared state: the current routing table (replaced as a whole on reload,
  # never mutated), the metrics counters and the auto-ban list.
  class State
    getter table : RoutingTable
    getter metrics : Metrics
    getter autoban : AutoBan

    def initialize(@table, @metrics, @autoban = AutoBan.new(AutoBanConfig.new))
    end

    def swap(new_table : RoutingTable) : Nil
      old = @table
      @table = new_table
      old.stop # tells the old health-check fibers to exit
    end
  end

  class Handler
    include HTTP::Handler

    HOP_BY_HOP = %w(connection keep-alive proxy-connection te trailer transfer-encoding upgrade proxy-authenticate proxy-authorization)

    def initialize(@state : State)
    end

    def call(context : HTTP::Server::Context) : Nil
      started = Time.instant
      request = context.request
      host = (request.headers["Host"]? || "").partition(':')[0]
      backend_url = ""
      bytes = 0_i64

      # Auto-ban: refuse clients that are in their cooldown before doing any other work.
      peer = client_ip(request)
      autoban = @state.autoban
      ban_key = autoban.enabled? ? autoban.client_key(peer, request.headers["X-Forwarded-For"]?) : peer
      banned_for = autoban.banned_for(ban_key)

      route = banned_for ? nil : @state.table.match(host, request.path)
      if banned_for
        autoban.rejected_total += 1
        context.response.headers["Retry-After"] = banned_for.to_s
        fail_with(context, 403, "Forbidden: too many error responses from your address, try again in #{banned_for}s")
      elsif route.nil?
        fail_with(context, 404, "Not Found: no route for #{host}#{request.path}")
      elsif backend = route.upstream.pick
        backend_url = backend.url
        # active is the least-connections signal; ensure guarantees we always
        # decrement, even when an exception unwinds the stack.
        backend.active += 1
        begin
          bytes = forward(context, backend)
        ensure
          backend.active -= 1
        end
      else
        fail_with(context, 502, "Bad Gateway: no healthy backend in pool '#{route.upstream.name}'")
      end

      status = context.response.status_code
      autoban.record(ban_key, status) unless banned_for # the ban's own 403 must not extend the ban

      elapsed = (Time.instant - started).total_milliseconds
      @state.metrics.record(Event.new(Time.utc, peer, request.method, host, request.resource,
        status, bytes, backend_url, elapsed))
    end

    # Returns the number of body bytes streamed back to the client.
    private def forward(context : HTTP::Server::Context, backend : Backend) : Int64
      request = context.request
      pool = backend.conn_pool
      client = pool.checkout
      committed = false
      bytes = 0_i64
      begin
        upstream_request = HTTP::Request.new(request.method, request.resource, outgoing_headers(request), request.body)
        client.exec(upstream_request) do |upstream|
          committed = true
          response = context.response
          response.status_code = upstream.status_code
          copy_headers(upstream.headers, response.headers)
          # Stream in chunks; the body is never held in memory as a whole.
          if io = upstream.body_io?
            bytes = IO.copy(io, response)
          end
        end
        pool.checkin(client) # body fully read -> socket is clean and reusable
        bytes
      rescue ex : IO::TimeoutError
        client.close
        Log.error { "504 #{backend.url}: #{ex.message}" }
        raise ex if committed
        fail_with(context, 504, "Gateway Timeout: #{backend.url} did not answer in time")
        0_i64
      rescue ex : IO::Error | Socket::Error
        client.close
        Log.error { "502 #{backend.url}: #{ex.class}: #{ex.message}" }
        raise ex if committed # headers already sent: all we can do is drop the connection
        fail_with(context, 502, "Bad Gateway: #{backend.url} refused or reset the connection")
        0_i64
      end
    end

    private def outgoing_headers(request : HTTP::Request) : HTTP::Headers
      headers = HTTP::Headers.new
      copy_headers(request.headers, headers)
      client = request.remote_address.try { |a| a.as?(Socket::IPAddress).try(&.address) } || "unknown"
      if previous = request.headers["X-Forwarded-For"]?
        headers["X-Forwarded-For"] = "#{previous}, #{client}"
      else
        headers["X-Forwarded-For"] = client
      end
      headers["X-Forwarded-Proto"] = "http"
      headers["X-Forwarded-Host"] = request.headers["Host"]? || ""
      headers
    end

    # Copies headers, dropping hop-by-hop ones and any header the Connection
    # header names (RFC 7230 section 6.1). Used in both directions.
    private def copy_headers(from : HTTP::Headers, to : HTTP::Headers) : Nil
      named = from["Connection"]?.try(&.split(',').map { |t| t.strip.downcase })
      from.each do |name, values|
        lower = name.downcase
        next if HOP_BY_HOP.includes?(lower)
        next if named && named.includes?(lower)
        to.add(name, values)
      end
    end

    private def fail_with(context : HTTP::Server::Context, status : Int32, message : String) : Nil
      response = context.response
      response.status_code = status
      response.content_type = "text/plain"
      response.print message, '\n'
    end

    private def client_ip(request : HTTP::Request) : String
      request.remote_address.try { |a| a.as?(Socket::IPAddress).try(&.address) } || "-"
    end
  end
end
