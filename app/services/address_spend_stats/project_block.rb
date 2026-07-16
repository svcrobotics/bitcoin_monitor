# frozen_string_literal: true

module AddressSpendStats
  class ProjectBlock
    ADVISORY_LOCK_NAMESPACE = 48_211

    PROJECTION_VERSION =
      AddressSpendStat::PROJECTION_VERSION

    class Error < StandardError; end
    class SourceUnavailable < Error; end
    class BlockHashMismatch < Error; end
    class InvalidAmount < Error; end

    def self.call(height:)
      new(height: height).call
    end

    def initialize(height:)
      @height = Integer(height)

      raise(
        ArgumentError,
        "height must be greater than or equal to zero"
      ) if @height.negative?
    end

    def call
      result = nil

      ApplicationRecord.transaction do
        acquire_lock!

        source_block =
          source_block!

        checkpoint =
          AddressSpendProjectionBlock
            .lock
            .find_by(
              height: height
            )

        validate_checkpoint_hash!(
          checkpoint: checkpoint,
          source_block: source_block
        )

        if checkpoint&.completed?
          result =
            checkpoint_result(
              checkpoint,
              idempotent: true
            )
        else
          checkpoint ||=
            AddressSpendProjectionBlock.new(
              height: height,
              block_hash:
                source_block.block_hash
            )

          checkpoint.update!(
            block_hash:
              source_block.block_hash,

            status:
              "processing",

            attempts:
              checkpoint.attempts.to_i + 1,

            processing_started_at:
              Time.current,

            completed_at:
              nil,

            error_message:
              nil
          )

          validate_source!

          metrics =
            project_rows!

          checkpoint.update!(
            status:
              "completed",

            input_count:
              metrics.fetch(
                :input_count
              ),

            address_count:
              metrics.fetch(
                :address_count
              ),

            total_sent_sats:
              metrics.fetch(
                :total_sent_sats
              ),

            completed_at:
              Time.current,

            error_message:
              nil,

            metadata:
              checkpoint
                .metadata
                .to_h
                .merge(
                  "source" =>
                    "cluster_inputs",

                  "projection_version" =>
                    PROJECTION_VERSION,

                  "upserted_addresses" =>
                    metrics.fetch(
                      :upserted_addresses
                    )
                )
          )

          result =
            checkpoint_result(
              checkpoint,
              idempotent: false
            )
        end

        admission_result = ActorProfiles::Admission.register_source(
          source_height: height,
          source_hash: source_block.block_hash,
          reason: "address_spend"
        )
        result = result.merge(actor_profile_admissions: admission_result)
      end

      result
    rescue BlockHashMismatch
      raise
    rescue StandardError => error
      record_failure!(
        error
      )

      raise
    end

    private

    attr_reader :height

    def connection
      ApplicationRecord.connection
    end

    def acquire_lock!
      connection.execute(
        "SELECT pg_advisory_xact_lock(" \
        "#{ADVISORY_LOCK_NAMESPACE}, " \
        "#{height})"
      )
    end

    def source_block!
      block =
        ClusterProcessedBlock.lock.find_by(
          height: height,
          status: "processed"
        )

      return block if block

      raise(
        SourceUnavailable,
        "Cluster checkpoint unavailable "         "height=#{height}"
      )
    end

    def validate_checkpoint_hash!(
      checkpoint:,
      source_block:
    )
      return unless checkpoint

      return if
        checkpoint.block_hash.to_s ==
          source_block.block_hash.to_s

      raise(
        BlockHashMismatch,
        "AddressSpend projection hash mismatch "         "height=#{height} "         "checkpoint_hash=#{checkpoint.block_hash} "         "cluster_hash=#{source_block.block_hash}"
      )
    end

    def validate_source!
      invalid_amounts =
        connection
          .select_value(
            <<~SQL.squish
              SELECT COUNT(*)

              FROM cluster_inputs

              WHERE #{source_conditions_sql}

                AND (
                  cluster_inputs.amount_btc
                    IS NULL

                  OR cluster_inputs.amount_btc
                    < 0
                )
            SQL
          )
          .to_i

      return if invalid_amounts.zero?

      raise(
        InvalidAmount,
        "Invalid cluster input amounts "         "height=#{height} "         "count=#{invalid_amounts}"
      )
    end

    def record_failure!(error)
      source =
        ClusterProcessedBlock.find_by(
          height: height,
          status: "processed"
        )

      return unless source

      ApplicationRecord.transaction do
        acquire_lock!

        checkpoint =
          AddressSpendProjectionBlock
            .lock
            .find_or_initialize_by(
              height: height
            )

        return if
          checkpoint.persisted? &&
          checkpoint.completed?

        failed_at =
          Time.current

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
            (
              "#{error.class}: " \
              "#{error.message}"
            ).first(2_000),

          metadata:
            checkpoint
              .metadata
              .to_h
              .merge(
                "failed_at" =>
                  failed_at.iso8601(6),

                "projection_version" =>
                  PROJECTION_VERSION
              )
        )

        checkpoint.save!
      end
    rescue StandardError => failure_error
      Rails.logger.error(
        "[address_spend_projection] " \
        "failure_checkpoint_error " \
        "height=#{height} " \
        "original_error=#{error.class}: " \
        "#{error.message} " \
        "checkpoint_error=" \
        "#{failure_error.class}: " \
        "#{failure_error.message}"
      )
    end

    def project_rows!
      quoted_version =
        connection.quote(
          PROJECTION_VERSION
        )

      result =
        connection.exec_query(
          <<~SQL.squish
            WITH per_address AS (
              SELECT
                cluster_inputs.address
                  AS address,

                COALESCE(
                  SUM(
                    (
                      cluster_inputs.amount_btc *
                      100000000
                    )::bigint
                  ),
                  0
                )::bigint
                  AS total_sent_sats,

                COUNT(*)::bigint
                  AS spent_inputs_count,

                MIN(
                  cluster_inputs.spent_block_height
                )::integer
                  AS first_spent_height,

                MAX(
                  cluster_inputs.spent_block_height
                )::integer
                  AS last_spent_height

              FROM cluster_inputs

              WHERE #{source_conditions_sql}

              GROUP BY
                cluster_inputs.address
            ),

            upserted AS (
              INSERT INTO address_spend_stats (
                address,
                total_sent_sats,
                spent_inputs_count,
                first_spent_height,
                last_spent_height,
                source_height,
                projection_version,
                created_at,
                updated_at
              )

              SELECT
                per_address.address,
                per_address.total_sent_sats,
                per_address.spent_inputs_count,
                per_address.first_spent_height,
                per_address.last_spent_height,
                #{height},
                #{quoted_version},
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP

              FROM per_address

              ON CONFLICT (address)
              DO UPDATE SET
                total_sent_sats =
                  address_spend_stats
                    .total_sent_sats +
                  EXCLUDED.total_sent_sats,

                spent_inputs_count =
                  address_spend_stats
                    .spent_inputs_count +
                  EXCLUDED.spent_inputs_count,

                first_spent_height =
                  CASE
                    WHEN
                      address_spend_stats
                        .first_spent_height
                        IS NULL
                    THEN
                      EXCLUDED.first_spent_height

                    WHEN
                      EXCLUDED.first_spent_height
                        IS NULL
                    THEN
                      address_spend_stats
                        .first_spent_height

                    ELSE
                      LEAST(
                        address_spend_stats
                          .first_spent_height,

                        EXCLUDED
                          .first_spent_height
                      )
                  END,

                last_spent_height =
                  CASE
                    WHEN
                      address_spend_stats
                        .last_spent_height
                        IS NULL
                    THEN
                      EXCLUDED.last_spent_height

                    WHEN
                      EXCLUDED.last_spent_height
                        IS NULL
                    THEN
                      address_spend_stats
                        .last_spent_height

                    ELSE
                      GREATEST(
                        address_spend_stats
                          .last_spent_height,

                        EXCLUDED
                          .last_spent_height
                      )
                  END,

                source_height =
                  GREATEST(
                    address_spend_stats
                      .source_height,

                    EXCLUDED.source_height
                  ),

                projection_version =
                  EXCLUDED.projection_version,

                updated_at =
                  CURRENT_TIMESTAMP

              RETURNING address
            )

            SELECT
              (
                SELECT COUNT(*)
                FROM cluster_inputs
                WHERE #{source_conditions_sql}
              )::bigint
                AS input_count,

              (
                SELECT COUNT(*)
                FROM per_address
              )::integer
                AS address_count,

              (
                SELECT COALESCE(
                  SUM(total_sent_sats),
                  0
                )
                FROM per_address
              )::bigint
                AS total_sent_sats,

              (
                SELECT COUNT(*)
                FROM upserted
              )::integer
                AS upserted_addresses
          SQL
        ).first

      {
        input_count:
          result.fetch(
            "input_count"
          ).to_i,

        address_count:
          result.fetch(
            "address_count"
          ).to_i,

        total_sent_sats:
          result.fetch(
            "total_sent_sats"
          ).to_i,

        upserted_addresses:
          result.fetch(
            "upserted_addresses"
          ).to_i
      }
    end

    def source_conditions_sql
      <<~SQL.squish
        cluster_inputs.spent_block_height =
          #{height}

        AND cluster_inputs.spent IS TRUE

        AND cluster_inputs.address
          IS NOT NULL

        AND cluster_inputs.address <> ''
      SQL
    end

    def checkpoint_result(
      checkpoint,
      idempotent:
    )
      {
        ok: true,
        height:
          checkpoint.height.to_i,

        block_hash:
          checkpoint.block_hash,

        status:
          checkpoint.status,

        input_count:
          checkpoint.input_count.to_i,

        address_count:
          checkpoint.address_count.to_i,

        total_sent_sats:
          checkpoint.total_sent_sats.to_i,

        attempts:
          checkpoint.attempts.to_i,

        idempotent:
          idempotent,

        completed_at:
          checkpoint.completed_at
      }
    end
  end
end
