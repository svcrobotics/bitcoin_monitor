# frozen_string_literal: true

module Clusters
  module Coverage
    class PrepareBlock
      SOURCE = "cluster_coverage_incremental_v1"
      BOOTSTRAP_SOURCE = "coverage_v1"
      BOOTSTRAP_MODE = "bootstrap"

      def self.call(height: nil)
        new(height: height).call
      end

      def initialize(height:)
        @height = height&.to_i
      end

      def call
        selected_height =
          height.presence ||
          next_height

        unless selected_height
          return {
            ok: true,
            prepared: false,
            deferred: true,
            reason: "no_eligible_projected_cluster_block"
          }
        end

        raise(
          ArgumentError,
          "height must be positive"
        ) unless selected_height.positive?

        cluster_block =
          ClusterProcessedBlock
            .where(
              height: selected_height,
              status: "processed"
            )
            .first

        unless cluster_block
          return {
            ok: true,
            prepared: false,
            deferred: true,
            height: selected_height,
            reason: "cluster_block_not_processed"
          }
        end

        projection =
          Layer1TxOutputProjectionBlock
            .find_by(height: selected_height)

        projection_check =
          projection_readiness(
            cluster_block: cluster_block,
            projection: projection
          )

        unless projection_check[:ready]
          record =
            record_deferred_or_failed!(
              cluster_block: cluster_block,
              reason: projection_check[:reason],
              failed: projection_check[:failed],
              details: projection_check[:details]
            )

          return {
            ok: !projection_check[:failed],
            prepared: false,
            deferred: !projection_check[:failed],
            failed: projection_check[:failed],
            height: selected_height,
            block_hash: cluster_block.block_hash,
            status: record.status,
            reason: projection_check[:reason],
            details: projection_check[:details]
          }
        end

        snapshot =
          build_snapshot(
            height: selected_height,
            block_hash: cluster_block.block_hash,
            projection: projection
          )

        record =
          prepare_record!(
            cluster_block: cluster_block,
            projection: projection,
            snapshot: snapshot
          )

        {
          ok: true,
          prepared: true,
          height: record.height,
          block_hash: record.block_hash,
          status: record.status,
          max_tx_output_id:
            record.max_tx_output_id,
          expected_outputs_count:
            record.expected_outputs_count,
          expected_address_outputs_count:
            record.expected_address_outputs_count,
          scripts_without_address_count:
            record.scripts_without_address_count,
          already_completed:
            record.completed?
        }
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      private

      attr_reader :height

      def next_height
        ClusterProcessedBlock
          .where(status: "processed")
          .joins(
            <<~SQL.squish
              INNER JOIN layer1_tx_output_projection_blocks
                ON layer1_tx_output_projection_blocks.height =
                   cluster_processed_blocks.height
              LEFT JOIN cluster_coverage_blocks
                ON cluster_coverage_blocks.height =
                   cluster_processed_blocks.height
            SQL
          )
          .where(
            "cluster_processed_blocks.height > ?",
            incremental_start_height
          )
          .where(
            "layer1_tx_output_projection_blocks.status = ?",
            "projected"
          )
          .where(
            "layer1_tx_output_projection_blocks.expected_outputs_count = " \
            "layer1_tx_output_projection_blocks.projected_outputs_count"
          )
          .where(
            "layer1_tx_output_projection_blocks.block_hash = " \
            "cluster_processed_blocks.block_hash"
          )
          .where(
            "cluster_coverage_blocks.id IS NULL " \
            "OR cluster_coverage_blocks.status <> ?",
            "completed"
          )
          .order(
            "cluster_processed_blocks.height ASC"
          )
          .limit(1)
          .pick(
            "cluster_processed_blocks.height"
          )
      end

      def incremental_start_height
        value =
          ClusterCoverageBlock
            .connection
            .select_value(
              <<~SQL.squish
                SELECT COALESCE(
                  MAX(
                    (metadata ->> 'incremental_start_height')::bigint
                  ),
                  0
                )
                FROM cluster_coverage_blocks
                WHERE status = 'completed'
                  AND metadata ->> 'mode' = #{quoted(BOOTSTRAP_MODE)}
                  AND metadata ->> 'source' = #{quoted(BOOTSTRAP_SOURCE)}
                  AND metadata ? 'incremental_start_height'
              SQL
            )

        value.to_i
      end

      def quoted(value)
        ClusterCoverageBlock
          .connection
          .quote(value)
      end

      def projection_readiness(
        cluster_block:,
        projection:
      )
        unless projection
          return {
            ready: false,
            failed: false,
            reason: "tx_output_projection_missing",
            details: {}
          }
        end

        if projection.block_hash.to_s !=
           cluster_block.block_hash.to_s

          return {
            ready: false,
            failed: true,
            reason: "projection_block_hash_mismatch",
            details: {
              cluster_block_hash:
                cluster_block.block_hash,
              projection_block_hash:
                projection.block_hash
            }
          }
        end

        unless projection.status == "projected"
          return {
            ready: false,
            failed: false,
            reason: "tx_output_projection_not_projected",
            details: {
              projection_status:
                projection.status
            }
          }
        end

        unless projection.expected_outputs_count.to_i ==
               projection.projected_outputs_count.to_i

          return {
            ready: false,
            failed: true,
            reason: "tx_output_projection_count_mismatch",
            details: {
              expected_outputs_count:
                projection.expected_outputs_count.to_i,
              projected_outputs_count:
                projection.projected_outputs_count.to_i
            }
          }
        end

        {
          ready: true,
          failed: false,
          reason: nil,
          details: {}
        }
      end

      def build_snapshot(
        height:,
        block_hash:,
        projection:
      )
        scope =
          TxOutput
            .where(
              block_height: height,
              block_hash: block_hash
            )

        max_tx_output_id =
          scope.maximum(:id)

        bounded_scope =
          if max_tx_output_id.present?
            scope.where(
              "id <= ?",
              max_tx_output_id
            )
          else
            scope.none
          end

        expected_outputs_count =
          bounded_scope.count

        if expected_outputs_count !=
           projection.projected_outputs_count.to_i

          raise(
            "Coverage projected outputs unavailable " \
            "height=#{height} " \
            "expected=#{projection.projected_outputs_count} " \
            "actual=#{expected_outputs_count}"
          )
        end

        addresses =
          bounded_scope
            .pluck(:address)

        scripts_without_address_count =
          addresses.count do |address|
            address.blank?
          end

        expected_address_outputs_count =
          addresses.count do |address|
            Clusters::Coverage::BitcoinAddressValidator
              .valid_bitcoin_address?(address)
          end

        invalid_address_outputs_count =
          addresses.count do |address|
            address.present? &&
              !Clusters::Coverage::BitcoinAddressValidator
                .valid_bitcoin_address?(address)
          end

        {
          max_tx_output_id:
            max_tx_output_id,

          expected_outputs_count:
            expected_outputs_count,

          expected_address_outputs_count:
            expected_address_outputs_count,

          scripts_without_address_count:
            scripts_without_address_count,

          invalid_address_outputs_count:
            invalid_address_outputs_count
        }
      end

      def prepare_record!(
        cluster_block:,
        projection:,
        snapshot:
      )
        ClusterCoverageBlock.transaction do
          record =
            ClusterCoverageBlock
              .lock
              .find_or_initialize_by(
                height: cluster_block.height
              )

          current_hash =
            cluster_block.block_hash.to_s

          hash_changed =
            record.persisted? &&
            record.block_hash.present? &&
            record.block_hash != current_hash

          if hash_changed
            reset_for_new_block!(
              record: record,
              block_hash: current_hash,
              projection: projection,
              snapshot: snapshot
            )
          elsif record.new_record?
            initialize_record!(
              record: record,
              block_hash: current_hash,
              projection: projection,
              snapshot: snapshot
            )
          elsif !record.completed?
            refresh_pending_record!(
              record: record,
              projection: projection,
              snapshot: snapshot
            )
          end

          record.save!
          record
        end
      end

      def initialize_record!(
        record:,
        block_hash:,
        projection:,
        snapshot:
      )
        record.assign_attributes(
          block_hash: block_hash,
          status: "pending",
          max_tx_output_id:
            snapshot[:max_tx_output_id],
          after_tx_output_id: nil,
          expected_outputs_count:
            snapshot[:expected_outputs_count],
          processed_outputs_count: 0,
          expected_address_outputs_count:
            snapshot[
              :expected_address_outputs_count
            ],
          processed_address_outputs_count: 0,
          scripts_without_address_count:
            snapshot[
              :scripts_without_address_count
            ],
          addresses_created_count: 0,
          singleton_clusters_created_count: 0,
          pages_processed: 0,
          attempts: 0,
          started_at: nil,
          completed_at: nil,
          last_error: nil,
          metadata: {
            "source" =>
              SOURCE,
            "prepared_at" =>
              Time.current.iso8601(6),
            "projection_checkpoint_id" =>
              projection.id,
            "projection_status" =>
              projection.status,
            "projection_expected_outputs_count" =>
              projection.expected_outputs_count.to_i,
            "projection_projected_outputs_count" =>
              projection.projected_outputs_count.to_i,
            "expected_invalid_address_outputs_count" =>
              snapshot[:invalid_address_outputs_count].to_i
          }
        )
      end

      def refresh_pending_record!(
        record:,
        projection:,
        snapshot:
      )
        return if record.status == "processing"

        record.assign_attributes(
          max_tx_output_id:
            snapshot[:max_tx_output_id],
          expected_outputs_count:
            snapshot[:expected_outputs_count],
          expected_address_outputs_count:
            snapshot[
              :expected_address_outputs_count
            ],
          scripts_without_address_count:
            snapshot[
              :scripts_without_address_count
            ]
        )

        record.metadata =
          record.metadata.to_h.merge(
            "prepared_at" =>
              Time.current.iso8601(6),
            "projection_checkpoint_id" =>
              projection.id,
            "projection_status" =>
              projection.status,
            "expected_invalid_address_outputs_count" =>
              snapshot[:invalid_address_outputs_count].to_i
          )
      end

      def reset_for_new_block!(
        record:,
        block_hash:,
        projection:,
        snapshot:
      )
        initialize_record!(
          record: record,
          block_hash: block_hash,
          projection: projection,
          snapshot: snapshot
        )

        record.metadata =
          record.metadata.to_h.merge(
            "reset_reason" =>
              "block_hash_changed"
          )
      end

      def record_deferred_or_failed!(
        cluster_block:,
        reason:,
        failed:,
        details:
      )
        ClusterCoverageBlock.transaction do
          record =
            ClusterCoverageBlock
              .lock
              .find_or_initialize_by(
                height: cluster_block.height
              )

          return record if record.completed?

          record.assign_attributes(
            block_hash: cluster_block.block_hash,
            status: failed ? "failed" : "deferred",
            completed_at: nil,
            last_error: failed ? reason : nil
          )

          record.metadata =
            record.metadata.to_h.merge(
              "source" =>
                SOURCE,
              "deferred_or_failed_at" =>
                Time.current.iso8601(6),
              "reason" =>
                reason,
              "details" =>
                details.stringify_keys
            )

          record.save!
          record
        end
      end
    end
  end
end
