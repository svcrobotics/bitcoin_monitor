# frozen_string_literal: true

module StrictPipeline
  class PostgresWriteBarrier
    OWNERS = %w[layer1 cluster].freeze

    # Advisory lock à deux clés.
    #
    # PostgreSQL maintient un espace distinct pour les advisory locks à deux
    # entiers : cette barrière ne peut donc pas entrer en collision avec les
    # advisory locks à une seule clé déjà utilisés par Cluster Coverage.
    LOCK_NAMESPACE = 1_946_071_541
    LOCK_RESOURCE = 1

    class LockUnavailable < StandardError; end
    class UnlockFailed < StandardError; end

    def self.with_lock(
      owner:,
      logger: Rails.logger,
      connection_pool: ActiveRecord::Base.connection_pool,
      &block
    )
      new(
        owner: owner,
        logger: logger,
        connection_pool: connection_pool
      ).with_lock(&block)
    end

    def initialize(owner:, logger:, connection_pool:)
      @owner = normalize_owner(owner)
      @logger = logger
      @connection_pool = connection_pool
    end

    def with_lock
      raise ArgumentError, "block required" unless block_given?

      @connection_pool.with_connection do |connection|
        acquired =
          postgres_true?(
            connection.select_value(try_lock_sql)
          )

        unless acquired
          @logger.info(
            "[postgres_write_barrier] " \
            "denied owner=#{@owner} " \
            "namespace=#{LOCK_NAMESPACE} resource=#{LOCK_RESOURCE}"
          )

          raise(
            LockUnavailable,
            "PostgreSQL strict writer barrier is already held"
          )
        end

        @logger.info(
          "[postgres_write_barrier] " \
          "acquired owner=#{@owner} " \
          "namespace=#{LOCK_NAMESPACE} resource=#{LOCK_RESOURCE}"
        )

        begin
          yield
        ensure
          release!(connection)
        end
      end
    end

    private

    def normalize_owner(owner)
      normalized = owner.to_s
      return normalized if OWNERS.include?(normalized)

      raise ArgumentError, "unknown PostgreSQL strict writer owner #{owner.inspect}"
    end

    def try_lock_sql
      <<~SQL.squish
        SELECT pg_try_advisory_lock(
          #{LOCK_NAMESPACE},
          #{LOCK_RESOURCE}
        )
      SQL
    end

    def unlock_sql
      <<~SQL.squish
        SELECT pg_advisory_unlock(
          #{LOCK_NAMESPACE},
          #{LOCK_RESOURCE}
        )
      SQL
    end

    def release!(connection)
      released =
        postgres_true?(
          connection.select_value(unlock_sql)
        )

      unless released
        disconnect_connection(connection)

        @logger.error(
          "[postgres_write_barrier] " \
          "release_denied owner=#{@owner} " \
          "namespace=#{LOCK_NAMESPACE} resource=#{LOCK_RESOURCE}"
        )

        raise(
          UnlockFailed,
          "PostgreSQL strict writer barrier could not be released"
        )
      end

      @logger.info(
        "[postgres_write_barrier] " \
        "released owner=#{@owner} " \
        "namespace=#{LOCK_NAMESPACE} resource=#{LOCK_RESOURCE}"
      )

      true
    rescue UnlockFailed
      raise
    rescue StandardError => error
      disconnect_connection(connection)

      @logger.error(
        "[postgres_write_barrier] " \
        "release_failed owner=#{@owner} " \
        "#{error.class}: #{error.message}"
      )

      raise(
        UnlockFailed,
        "PostgreSQL strict writer barrier release failed: " \
        "#{error.class}: #{error.message}"
      )
    end

    def disconnect_connection(connection)
      connection.disconnect! if connection.respond_to?(:disconnect!)
    rescue StandardError => error
      @logger.error(
        "[postgres_write_barrier] " \
        "connection_disconnect_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def postgres_true?(value)
      value == true ||
        value.to_s == "t" ||
        value.to_s == "true" ||
        value.to_s == "1"
    end
  end
end
