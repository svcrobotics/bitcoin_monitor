# frozen_string_literal: true

require "time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"
require_relative "block_delta_builder"

module AddressUtxoStats
  class ProjectBlock
    ADVISORY_LOCK_NAMESPACE =
      48_212

    PROJECTION_VERSION =
      AddressUtxoStat::PROJECTION_VERSION

    BLOCK_DELTA_BUILDER_VERSION =
      "strict_v1_block_delta_builder"

    class Error < StandardError; end
    class ClusterCheckpointUnavailable < Error; end
    class ClusterCheckpointNotProcessed < Error; end
    class ClusterCheckpointHashMissing < Error; end
    class BlockHashMismatch < Error; end
    class DeltaAnomaliesDetected < Error
      attr_reader :delta_result

      def initialize(delta_result)
        @delta_result =
          delta_result

        super("AddressUtxo block delta anomalies detected")
      end
    end

    class FinalStateInvalid < Error; end

    DefaultClusterCheckpointResolver =
      lambda do |height:|
        model =
          "ClusterProcessedBlock".safe_constantize

        model&.find_by(
          height: height
        )
      end

    DefaultAdvisoryLock =
      lambda do |height:, connection:|
        connection.execute(
          "SELECT pg_advisory_xact_lock(" \
          "#{ADVISORY_LOCK_NAMESPACE}, " \
          "#{height})"
        )
      end

    def self.call(**attributes)
      new(**attributes).call
    end

    def initialize(
      height:,
      block_hash: nil,
      utxo_outputs: nil,
      cluster_inputs: nil,
      block_delta_builder: BlockDeltaBuilder,
      cluster_checkpoint_resolver: DefaultClusterCheckpointResolver,
      lock_manager: DefaultAdvisoryLock
    )
      @height =
        Integer(height)

      raise(
        ArgumentError,
        "height must be greater than or equal to zero"
      ) if @height.negative?

      @expected_block_hash =
        block_hash

      @utxo_outputs =
        utxo_outputs

      @cluster_inputs =
        cluster_inputs

      @block_delta_builder =
        block_delta_builder

      @cluster_checkpoint_resolver =
        cluster_checkpoint_resolver

      @lock_manager =
        lock_manager
    end

    def call
      started_at =
        monotonic_time

      result = nil

      ApplicationRecord.transaction do
        acquire_lock!

        cluster_checkpoint =
          cluster_checkpoint!

        checkpoint =
          AddressUtxoProjectionBlock
            .lock
            .find_by(
              height: height
            )

        validate_existing_checkpoint_hash!(
          checkpoint: checkpoint,
          cluster_checkpoint: cluster_checkpoint
        )

        if checkpoint&.completed?
          result =
            checkpoint_result(
              checkpoint,
              idempotent: true,
              addresses_written: 0,
              status: "already_completed",
              started_at: started_at
            )

          next
        end

        checkpoint ||=
          AddressUtxoProjectionBlock.new(
            height: height,
            block_hash:
              cluster_checkpoint.block_hash
          )

        checkpoint.update!(
          block_hash:
            cluster_checkpoint.block_hash,
          status:
            "processing",
          attempts:
            checkpoint.attempts.to_i + 1,
          processing_started_at:
            Time.current,
          completed_at:
            nil,
          error_message:
            nil,
          metadata:
            checkpoint.metadata.to_h.merge(
              "projection_version" =>
                PROJECTION_VERSION,
              "block_delta_builder_version" =>
                BLOCK_DELTA_BUILDER_VERSION,
              "mode" =>
                "single_block_atomic"
            )
        )

        delta_result =
          build_delta(
            cluster_checkpoint: cluster_checkpoint
          )

        if delta_result.fetch(:anomalies).any?
          raise(
            DeltaAnomaliesDetected,
            delta_result
          )
        end

        addresses_written =
          apply_deltas!(
            delta_result.fetch(:deltas)
          )

        checkpoint.update!(
          status:
            "completed",
          received_output_count:
            delta_result.fetch(:received_output_count),
          spent_output_count:
            delta_result.fetch(:spent_output_count),
          received_address_count:
            delta_result.fetch(:received_address_count),
          spent_address_count:
            delta_result.fetch(:spent_address_count),
          total_received_sats:
            delta_result.fetch(:total_received_sats),
          total_spent_sats:
            delta_result.fetch(:total_spent_sats),
          completed_at:
            Time.current,
          error_message:
            nil,
          metadata:
            checkpoint.metadata.to_h.merge(
              "projection_version" =>
                PROJECTION_VERSION,
              "block_delta_builder_version" =>
                BLOCK_DELTA_BUILDER_VERSION,
              "addresses_touched" =>
                delta_result.fetch(:addresses_touched),
              "addresses_written" =>
                addresses_written,
              "balance_delta_sats" =>
                delta_result.fetch(:balance_delta_sats),
              "mode" =>
                "single_block_atomic"
            )
        )

        result =
          checkpoint_result(
            checkpoint,
            idempotent: false,
            addresses_written: addresses_written,
            status: "completed",
            started_at: started_at
          )
      end

      result
    rescue ClusterCheckpointUnavailable,
           ClusterCheckpointNotProcessed,
           ClusterCheckpointHashMissing,
           BlockHashMismatch => error
      blocked_result(
        error,
        started_at: started_at
      )
    rescue DeltaAnomaliesDetected => error
      record_failure!(
        error,
        delta_result: error.delta_result
      )

      blocked_result(
        error,
        started_at: started_at,
        delta_result: error.delta_result
      )
    rescue StandardError => error
      record_failure!(
        error
      )

      failed_result(
        error,
        started_at: started_at
      )
    end

    private

    attr_reader(
      :height,
      :expected_block_hash,
      :utxo_outputs,
      :cluster_inputs,
      :block_delta_builder,
      :cluster_checkpoint_resolver,
      :lock_manager
    )

    def connection
      ApplicationRecord.connection
    end

    def acquire_lock!
      lock_manager.call(
        height: height,
        connection: connection
      )
    end

    def cluster_checkpoint!
      checkpoint =
        cluster_checkpoint_resolver.call(
          height: height
        )

      unless checkpoint
        raise(
          ClusterCheckpointUnavailable,
          "Cluster checkpoint unavailable height=#{height}"
        )
      end

      unless checkpoint.status.to_s == "processed"
        raise(
          ClusterCheckpointNotProcessed,
          "Cluster checkpoint is not processed height=#{height}"
        )
      end

      if checkpoint.block_hash.blank?
        raise(
          ClusterCheckpointHashMissing,
          "Cluster checkpoint block_hash missing height=#{height}"
        )
      end

      if expected_block_hash.present? &&
         expected_block_hash.to_s != checkpoint.block_hash.to_s
        raise(
          BlockHashMismatch,
          "Expected block_hash does not match Cluster checkpoint " \
          "height=#{height}"
        )
      end

      checkpoint
    end

    def validate_existing_checkpoint_hash!(
      checkpoint:,
      cluster_checkpoint:
    )
      return unless checkpoint
      return if checkpoint.block_hash.to_s ==
                cluster_checkpoint.block_hash.to_s

      raise(
        BlockHashMismatch,
        "AddressUtxo projection hash mismatch height=#{height} " \
        "checkpoint_hash=#{checkpoint.block_hash} " \
        "cluster_hash=#{cluster_checkpoint.block_hash}"
      )
    end

    def build_delta(cluster_checkpoint:)
      block_delta_builder.call(
        height: height,
        block_hash: cluster_checkpoint.block_hash,
        utxo_outputs: utxo_outputs,
        cluster_inputs: cluster_inputs
      )
    end

    def apply_deltas!(deltas)
      deltas.sum do |delta|
        apply_delta!(
          delta
        )

        1
      end
    end

    def apply_delta!(delta)
      return if update_existing_delta!(
        delta
      )

      if address_exists?(
        delta.fetch(:address)
      )
        raise_final_state_invalid!(
          delta
        )
      end

      insert_new_delta!(
        delta
      )
    end

    def update_existing_delta!(delta)
      result =
        connection.exec_query(
          update_sql(
            delta
          )
        )

      result.rows.one?
    end

    def insert_new_delta!(delta)
      validate_initial_state!(
        delta
      )

      result =
        connection.exec_query(
          insert_sql(
            delta
          )
        )

      return if result.rows.one?

      raise_final_state_invalid!(
        delta
      )
    rescue ActiveRecord::RecordNotUnique,
           ActiveRecord::StatementInvalid => error
      raise unless unique_violation?(error)

      return if update_existing_delta!(
        delta
      )

      raise_final_state_invalid!(
        delta
      )
    end

    def update_sql(delta)
      address =
        connection.quote(
          delta.fetch(:address)
        )

      version =
        connection.quote(
          PROJECTION_VERSION
        )

      first_height =
        sql_integer_or_null(
          delta.fetch(
            :first_received_height_candidate
          )
        )

      last_height =
        sql_integer_or_null(
          delta.fetch(
            :last_received_height_candidate
          )
        )

      <<~SQL.squish
        WITH candidate AS (
          SELECT
            id,

            total_received_sats +
              #{integer_sql(delta.fetch(:received_sats_delta))}
                AS final_total_received_sats,

            current_balance_sats +
              #{integer_sql(delta.fetch(:balance_sats_delta))}
                AS final_current_balance_sats,

            live_utxo_count +
              #{integer_sql(delta.fetch(:live_utxo_count_delta))}
                AS final_live_utxo_count,

            received_output_count +
              #{integer_sql(delta.fetch(:received_output_count_delta))}
                AS final_received_output_count,

            CASE
              WHEN first_received_height IS NULL
              THEN #{first_height}

              WHEN #{first_height} IS NULL
              THEN first_received_height

              ELSE LEAST(
                first_received_height,
                #{first_height}
              )
            END
              AS final_first_received_height,

            CASE
              WHEN last_received_height IS NULL
              THEN #{last_height}

              WHEN #{last_height} IS NULL
              THEN last_received_height

              ELSE GREATEST(
                last_received_height,
                #{last_height}
              )
            END
              AS final_last_received_height

          FROM address_utxo_stats

          WHERE address = #{address}
        )

        UPDATE address_utxo_stats

        SET
          total_received_sats =
            candidate.final_total_received_sats,

          current_balance_sats =
            candidate.final_current_balance_sats,

          live_utxo_count =
            candidate.final_live_utxo_count,

          received_output_count =
            candidate.final_received_output_count,

          first_received_height =
            candidate.final_first_received_height,

          last_received_height =
            candidate.final_last_received_height,

          last_changed_height =
            #{integer_sql(height)},

          projection_version =
            #{version},

          updated_at =
            CURRENT_TIMESTAMP

        FROM candidate

        WHERE address_utxo_stats.id = candidate.id

          AND candidate.final_total_received_sats >= 0

          AND candidate.final_current_balance_sats >= 0

          AND candidate.final_live_utxo_count >= 0

          AND candidate.final_received_output_count >= 0

          AND candidate.final_current_balance_sats <=
            candidate.final_total_received_sats

          AND (
            candidate.final_first_received_height IS NULL
            OR candidate.final_last_received_height IS NULL
            OR candidate.final_first_received_height <=
              candidate.final_last_received_height
          )

        RETURNING address_utxo_stats.address
      SQL
    end

    def insert_sql(delta)
      address =
        connection.quote(
          delta.fetch(:address)
        )

      version =
        connection.quote(
          PROJECTION_VERSION
        )

      first_height =
        sql_integer_or_null(
          delta.fetch(
            :first_received_height_candidate
          )
        )

      last_height =
        sql_integer_or_null(
          delta.fetch(
            :last_received_height_candidate
          )
        )

      <<~SQL.squish
        INSERT INTO address_utxo_stats (
          address,
          total_received_sats,
          current_balance_sats,
          live_utxo_count,
          received_output_count,
          first_received_height,
          last_received_height,
          last_changed_height,
          projection_version,
          metadata,
          created_at,
          updated_at
        )

        VALUES (
          #{address},
          #{integer_sql(delta.fetch(:received_sats_delta))},
          #{integer_sql(delta.fetch(:balance_sats_delta))},
          #{integer_sql(delta.fetch(:live_utxo_count_delta))},
          #{integer_sql(delta.fetch(:received_output_count_delta))},
          #{first_height},
          #{last_height},
          #{integer_sql(height)},
          #{version},
          '{}'::jsonb,
          CURRENT_TIMESTAMP,
          CURRENT_TIMESTAMP
        )

        RETURNING address
      SQL
    end

    def validate_initial_state!(delta)
      address =
        delta.fetch(:address)

      total_received_sats =
        Integer(
          delta.fetch(:received_sats_delta)
        )

      current_balance_sats =
        Integer(
          delta.fetch(:balance_sats_delta)
        )

      live_utxo_count =
        Integer(
          delta.fetch(:live_utxo_count_delta)
        )

      received_output_count =
        Integer(
          delta.fetch(:received_output_count_delta)
        )

      first_height =
        delta.fetch(
          :first_received_height_candidate
        )

      last_height =
        delta.fetch(
          :last_received_height_candidate
        )

      return if address.present? &&
                total_received_sats >= 0 &&
                current_balance_sats >= 0 &&
                live_utxo_count >= 0 &&
                received_output_count >= 0 &&
                current_balance_sats <= total_received_sats &&
                (
                  first_height.nil? ||
                  last_height.nil? ||
                  first_height <= last_height
                )

      raise_final_state_invalid!(
        delta
      )
    end

    def address_exists?(address)
      connection
        .select_value(
          <<~SQL.squish
            SELECT 1

            FROM address_utxo_stats

            WHERE address = #{connection.quote(address)}

            LIMIT 1
          SQL
        )
        .present?
    end

    def unique_violation?(error)
      cause =
        error.cause

      cause.class.name == "PG::UniqueViolation"
    end

    def raise_final_state_invalid!(delta)
      raise(
        FinalStateInvalid,
        "AddressUtxo final state invalid " \
        "height=#{height} " \
        "address=#{delta.fetch(:address)}"
      )
    end

    def record_failure!(error, delta_result: nil)
      source =
        cluster_checkpoint_resolver.call(
          height: height
        )

      return unless source&.block_hash.present?

      ApplicationRecord.transaction do
        acquire_lock!

        checkpoint =
          AddressUtxoProjectionBlock
            .lock
            .find_or_initialize_by(
              height: height
            )

        return if checkpoint.persisted? &&
                  checkpoint.completed?

        failed_at =
          Time.current

        metadata =
          checkpoint.metadata.to_h.merge(
            "projection_version" =>
              PROJECTION_VERSION,
            "block_delta_builder_version" =>
              BLOCK_DELTA_BUILDER_VERSION,
            "failed_at" =>
              failed_at.iso8601(6),
            "error_class" =>
              error.class.name
          )

        if delta_result
          metadata["anomalies"] =
            delta_result.fetch(:anomalies)

          metadata["addresses_touched"] =
            delta_result.fetch(:addresses_touched)
        end

        checkpoint.assign_attributes(
          block_hash:
            source.block_hash,
          status:
            "failed",
          attempts:
            checkpoint.attempts.to_i + 1,
          processing_started_at:
            checkpoint.processing_started_at ||
            failed_at,
          completed_at:
            nil,
          error_message:
            "#{error.class}: #{error.message}"[0, 2_000],
          metadata:
            metadata
        )

        checkpoint.save!
      end
    rescue StandardError => failure_error
      Rails.logger.error(
        "[address_utxo_projection] failure_checkpoint_error " \
        "height=#{height} " \
        "original_error=#{error.class}: #{error.message} " \
        "checkpoint_error=#{failure_error.class}: " \
        "#{failure_error.message}"
      )
    end

    def checkpoint_result(
      checkpoint,
      idempotent:,
      addresses_written:,
      status:,
      started_at:
    )
      {
        ok:
          true,
        status:
          status,
        height:
          checkpoint.height.to_i,
        block_hash:
          checkpoint.block_hash,
        idempotent:
          idempotent,
        received_output_count:
          checkpoint.received_output_count.to_i,
        spent_output_count:
          checkpoint.spent_output_count.to_i,
        received_address_count:
          checkpoint.received_address_count.to_i,
        spent_address_count:
          checkpoint.spent_address_count.to_i,
        total_received_sats:
          checkpoint.total_received_sats.to_i,
        total_spent_sats:
          checkpoint.total_spent_sats.to_i,
        addresses_written:
          addresses_written,
        attempts:
          checkpoint.attempts.to_i,
        checkpoint:
          checkpoint_payload(checkpoint),
        completed_at:
          checkpoint.completed_at,
        duration_ms:
          elapsed_ms(started_at)
      }
    end

    def blocked_result(
      error,
      started_at:,
      delta_result: nil
    )
      result = {
        ok:
          false,
        status:
          "blocked",
        height:
          height,
        block_hash:
          nil,
        idempotent:
          false,
        addresses_written:
          0,
        error:
          error_payload(error),
        duration_ms:
          elapsed_ms(started_at)
      }

      return result unless delta_result

      result.merge(
        block_hash:
          delta_result[:block_hash],
        received_output_count:
          delta_result.fetch(:received_output_count),
        spent_output_count:
          delta_result.fetch(:spent_output_count),
        received_address_count:
          delta_result.fetch(:received_address_count),
        spent_address_count:
          delta_result.fetch(:spent_address_count),
        total_received_sats:
          delta_result.fetch(:total_received_sats),
        total_spent_sats:
          delta_result.fetch(:total_spent_sats),
        anomalies:
          delta_result.fetch(:anomalies)
      )
    end

    def failed_result(error, started_at:)
      checkpoint =
        AddressUtxoProjectionBlock.find_by(
          height: height
        )

      {
        ok:
          false,
        status:
          "failed",
        height:
          height,
        block_hash:
          checkpoint&.block_hash,
        idempotent:
          false,
        addresses_written:
          0,
        checkpoint:
          checkpoint && checkpoint_payload(checkpoint),
        error:
          error_payload(error),
        duration_ms:
          elapsed_ms(started_at)
      }
    end

    def checkpoint_payload(checkpoint)
      {
        id:
          checkpoint.id,
        height:
          checkpoint.height.to_i,
        block_hash:
          checkpoint.block_hash,
        status:
          checkpoint.status,
        attempts:
          checkpoint.attempts.to_i,
        completed_at:
          checkpoint.completed_at,
        metadata:
          checkpoint.metadata.to_h
      }
    end

    def error_payload(error)
      {
        code:
          error_code(error),
        class:
          error.class.name,
        message:
          error.message
      }
    end

    def error_code(error)
      error.class.name.demodulize.underscore
    end

    def integer_sql(value)
      Integer(value).to_s
    end

    def sql_integer_or_null(value)
      return "NULL" if value.nil?

      integer_sql(value)
    end

    def monotonic_time
      Process.clock_gettime(
        Process::CLOCK_MONOTONIC
      )
    end

    def elapsed_ms(started_at)
      (
        (
          monotonic_time -
          started_at
        ) * 1000
      ).round
    end
  end
end
