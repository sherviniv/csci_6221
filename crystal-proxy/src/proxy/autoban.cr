require "log"
require "./config"

module Proxy
  class AutoBan
    # What we remember about one client.
    class Entry
      property count = 0 # counted responses in the current window
      property window_started : Time::Instant
      property banned_until : Time::Instant? = nil

      def initialize(@window_started : Time::Instant)
      end
    end

    getter config : AutoBanConfig
    property bans_total = 0_i64     # bans issued since start
    property rejected_total = 0_i64 # requests refused because the client was banned

    def initialize(@config : AutoBanConfig)
      @entries = {} of String => Entry
    end

    # Used by a config reload. Existing bans stay; turning the feature off forgets them.
    def configure(config : AutoBanConfig) : Nil
      @config = config
      @entries.clear unless enabled?
    end

    def enabled? : Bool
      @config.threshold > 0
    end

    # The address we ban: the socket peer, or the last X-Forwarded-For entry if trusted.
    def client_key(peer : String, forwarded : String?) : String
      return peer unless @config.trust_forwarded_for
      last = forwarded.try(&.split(',').last?.try(&.strip))
      last.nil? || last.empty? ? peer : last
    end

    # Seconds of cooldown left if this client is banned, else nil.
    def banned_for(key : String, now : Time::Instant = Time.instant) : Int32?
      return nil unless enabled?
      ends_at = @entries[key]?.try(&.banned_until)
      return nil unless ends_at
      left = ends_at - now
      if left.positive?
        left.total_seconds.ceil.to_i
      else
        @entries.delete(key) # cooldown over: forget the client, fresh start
        nil
      end
    end

    # Call after every response that was not itself a ban rejection.
    def record(key : String, status : Int32, now : Time::Instant = Time.instant) : Nil
      return unless enabled? && @config.statuses.includes?(status)

      entry = @entries[key]?
      if entry.nil?
        if @entries.size >= @config.max_tracked
          sweep(now)
          # Still full of live entries: stop tracking new clients (fail open) so memory stays bounded.
          return if @entries.size >= @config.max_tracked
        end
        entry = Entry.new(now)
        @entries[key] = entry
      end

      if ends_at = entry.banned_until
        return if ends_at > now  # already banned
        entry.banned_until = nil # an old ban that nobody cleaned up yet: start over
        entry.count = 0
        entry.window_started = now
      end

      if now - entry.window_started > @config.window_seconds.seconds
        entry.count = 0
        entry.window_started = now
      end
      entry.count += 1

      if entry.count >= @config.threshold
        entry.banned_until = now + @config.ban_seconds.seconds
        @bans_total += 1
        Log.warn { "autoban: #{key} banned for #{@config.ban_seconds}s (#{entry.count} errors within #{@config.window_seconds}s)" }
      end
    end

    # Forget finished bans and idle counting windows.
    def sweep(now : Time::Instant = Time.instant) : Nil
      window = @config.window_seconds.seconds
      @entries.reject! do |_, entry|
        if ends_at = entry.banned_until
          ends_at <= now
        else
          now - entry.window_started > window
        end
      end
    end

    # Currently banned clients with their remaining cooldown, longest first.
    def banned(now : Time::Instant = Time.instant) : Array({String, Int32})
      list = [] of {String, Int32}
      @entries.each do |key, entry|
        next unless ends_at = entry.banned_until
        left = ends_at - now
        list << {key, left.total_seconds.ceil.to_i} if left.positive?
      end
      list.sort_by { |_, seconds| -seconds }
    end

    def unban(key : String) : Bool
      !@entries.delete(key).nil?
    end

    def unban_all : Int32
      count = banned.size
      @entries.clear
      count
    end

    def start_sweeper : Nil
      spawn(name: "autoban sweep") do
        loop do
          sleep 30.seconds
          sweep
        end
      end
    end
  end
end
