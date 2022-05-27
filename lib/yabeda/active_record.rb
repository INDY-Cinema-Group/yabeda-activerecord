# frozen_string_literal: true

require "yabeda"
require "active_record"

require_relative "active_record/version"

module Yabeda
  # ActiveRecord Yabeda plugin to collect metrics for query performance, connection pool stats, etc
  module ActiveRecord
    class Error < StandardError; end

    LONG_RUNNING_QUERY_RUNTIME_BUCKETS = [
      0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, # standard (from Prometheus)
      30, 60, 120, 300, 1800, 3600, 21_600, # Well, sometime queries can execute way too long
    ].freeze

    # rubocop: disable Layout/LineLength
    Yabeda.configure do
      group :activerecord do
        counter   :queries_total, tags: %i[config kind cached async],
                                  comment: "Total number of SQL queries issued by application via ActiveRecord"
        histogram :query_duration, tags: %i[config kind cached async],
                                   unit: :seconds, buckets: LONG_RUNNING_QUERY_RUNTIME_BUCKETS,
                                   comment: "Duration of SQL queries generated by ActiveRecord"

        gauge :connection_pool_size,
              tags: %i[config],
              comment: "Connection pool size"
        gauge :connection_pool_connections,
              tags: %i[config],
              comment: "Total number of connections currently created in the pool (sum of busy, dead, and idle)."
        gauge :connection_pool_busy,
              tags: %i[config],
              comment: "Number of connections that has been checked out by some thread and are in use now."
        gauge :connection_pool_dead,
              tags: %i[config],
              comment: "Number of lost connections for the pool. A lost connection can occur if a programmer forgets to checkin a connection at the end of a thread or a thread dies unexpectedly."
        gauge :connection_pool_idle,
              tags: %i[config],
              comment: "Number of free connections, that are available for checkout."
        gauge :connection_pool_waiting,
              tags: %i[config],
              comment: "Number of threads waiting for a connection to become available for checkout."
        gauge :connection_pool_checkout_timeout,
              tags: %i[config],
              unit: :seconds,
              comment: "Checkout waiting timeout in seconds"
      end
      # rubocop: enable Layout/LineLength

      # Query performance metrics collection
      ActiveSupport::Notifications.subscribe "sql.active_record" do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)

        pool = event.payload[:connection].pool
        next if !pool || pool.is_a?(::ActiveRecord::ConnectionAdapters::NullPool)

        db_config_name = pool.respond_to?(:db_config) ? pool.db_config.name : pool.spec.name

        labels = {
          config: db_config_name,
          kind: event.payload[:name],
          cached: !event.payload[:cached].nil?,
          async: !event.payload[:async].nil?,
        }

        Yabeda.activerecord.queries_total.increment(labels)
        Yabeda.activerecord.query_duration.measure(labels, (event.duration.to_f / 1000).round(3))
      end

      # Connection pool metrics collection
      collect do
        connection_pools = ::ActiveRecord::Base.connection_handler.connection_pool_list

        connection_pools.each do |connection_pool|
          stats = connection_pool.stat
          name =
            if connection_pool.respond_to?(:db_config)
              connection_pool.db_config.name
            else
              connection_pool.spec.name
            end

          tags = { config: name }
          Yabeda.activerecord.connection_pool_size.set(tags, stats[:size])
          Yabeda.activerecord.connection_pool_connections.set(tags, stats[:connections])
          Yabeda.activerecord.connection_pool_busy.set(tags, stats[:busy])
          Yabeda.activerecord.connection_pool_dead.set(tags, stats[:dead])
          Yabeda.activerecord.connection_pool_idle.set(tags, stats[:idle])
          Yabeda.activerecord.connection_pool_waiting.set(tags, stats[:waiting])
          Yabeda.activerecord.connection_pool_checkout_timeout.set(tags, stats[:checkout_timeout])
        end
      end
    end
  end
end
