# frozen_string_literal: true

require "set"

module Clusters
  module Coverage
    class ProcessPage
      DEFAULT_BATCH_SIZE =
        ENV.fetch(
          "CLUSTER_COVERAGE_BATCH_SIZE",
          "500"
        ).to_i

      SOURCE = "cluster_coverage_incremental_v1"

      ADVISORY_LOCK_NAMESPACE = 47_311

      def self.call(
        height:,
        batch_size: DEFAULT_BATCH_SIZE
      )
        new(
          height: height,
          batch_size: batch_size
        ).call
      end

      def initialize(height:, batch_size:)
        @height = height.to_i
        @batch_size =
          [
            batch_size.to_i,
            1
          ].max
      end

      def call
        raise(
          ArgumentError,
          "height must be positive"
        ) unless height.positive?

        result =
          ApplicationRecord.transaction do
            acquire_lock!

            coverage =
              ClusterCoverageBlock
                .lock
                .find_by!(height: height)

            if coverage.completed?
              next completed_result(
                coverage,
                already_completed: true
              )
            end

            verify_block!(coverage)
            mark_processing!(coverage)

            page_rows =
              load_page(coverage)

            if page_rows.empty?
              finalize!(coverage)
              coverage.save!

              next build_result(
                coverage: coverage,
                page_rows: [],
                distinct_addresses: 0,
                addresses_created: 0,
                singletons_created: 0
              )
            end

            addresses =
              page_rows
                .filter_map do |_id, address|
                  valid_address(address) ? address : nil
                end
                .uniq

            addresses_created =
              upsert_addresses!(
                addresses: addresses,
                height: coverage.height
              )

            singleton_result =
              Clusters::EnsureAddressClusters.call(
                addresses: addresses,
                mark_dirty: false
              )

            unresolved_count =
              unresolved_addresses_count(
                addresses
              )

            if unresolved_count.positive?
              raise(
                "Coverage page left unresolved addresses " \
                "height=#{height} " \
                "count=#{unresolved_count}"
              )
            end

            address_output_rows =
              page_rows.count do |_id, address|
                valid_address(address)
              end

            invalid_address_rows =
              page_rows.count do |_id, address|
                address.present? &&
                  !valid_address(address)
              end

            scripts_without_address_rows =
              page_rows.count do |_id, address|
                address.blank?
              end

            coverage.assign_attributes(
              after_tx_output_id:
                page_rows.last.first,

              processed_outputs_count:
                coverage
                  .processed_outputs_count
                  .to_i +
                page_rows.size,

              processed_address_outputs_count:
                coverage
                  .processed_address_outputs_count
                  .to_i +
                address_output_rows,

              addresses_created_count:
                coverage
                  .addresses_created_count
                  .to_i +
                addresses_created,

              singleton_clusters_created_count:
                coverage
                  .singleton_clusters_created_count
                  .to_i +
                singleton_result[:clusters].to_i,

              pages_processed:
                coverage.pages_processed.to_i + 1,

              last_error:
                nil
            )

            coverage.metadata =
              coverage.metadata.to_h.merge(
                "last_page_at" =>
                  Time.current.iso8601(6),

                "last_page_first_tx_output_id" =>
                  page_rows.first.first,

                "last_page_last_tx_output_id" =>
                  page_rows.last.first,

                "last_page_outputs_count" =>
                  page_rows.size,

                "last_page_address_outputs_count" =>
                  address_output_rows,

                "last_page_invalid_address_outputs_count" =>
                  invalid_address_rows,

                "last_page_scripts_without_address_count" =>
                  scripts_without_address_rows,

                "last_page_distinct_addresses_count" =>
                  addresses.size,

                "last_page_addresses_created_count" =>
                  addresses_created,

                "last_page_singletons_created_count" =>
                  singleton_result[:clusters].to_i,

                "actor_profile_dirty_marking" =>
                  false
              )

            if final_page?(coverage)
              finalize!(coverage)
            end

            coverage.save!

            build_result(
              coverage: coverage,
              page_rows: page_rows,
              distinct_addresses: addresses.size,
              addresses_created: addresses_created,
              singletons_created:
                singleton_result[:clusters].to_i
            )
          end

        result
      rescue StandardError => error
        mark_failed!(error)
        raise
      end

      private

      attr_reader :height, :batch_size

      def acquire_lock!
        ActiveRecord::Base
          .connection
          .select_value(
            "SELECT pg_advisory_xact_lock(" \
            "#{ADVISORY_LOCK_NAMESPACE}, " \
            "#{height})"
          )
      end

      def verify_block!(coverage)
        cluster_block =
          ClusterProcessedBlock.find_by(
            height: height,
            status: "processed"
          )

        unless cluster_block
          raise(
            "Cluster processed block unavailable " \
            "height=#{height}"
          )
        end

        if cluster_block.block_hash.to_s !=
           coverage.block_hash.to_s

          raise(
            "Cluster block hash changed " \
            "height=#{height} " \
            "expected=#{coverage.block_hash} " \
            "actual=#{cluster_block.block_hash}"
          )
        end

        projection =
          Layer1TxOutputProjectionBlock.find_by(
            height: height
          )

        unless projection
          raise(
            "TxOutput projection checkpoint missing " \
            "height=#{height}"
          )
        end

        if projection.block_hash.to_s !=
           coverage.block_hash.to_s

          raise(
            "TxOutput projection block hash mismatch " \
            "height=#{height} " \
            "expected=#{coverage.block_hash} " \
            "actual=#{projection.block_hash}"
          )
        end

        unless projection.status == "projected"
          raise(
            "TxOutput projection not ready " \
            "height=#{height} " \
            "status=#{projection.status}"
          )
        end

        unless projection.expected_outputs_count.to_i ==
               projection.projected_outputs_count.to_i

          raise(
            "TxOutput projection count mismatch " \
            "height=#{height} " \
            "expected=#{
              projection.expected_outputs_count
            } " \
            "projected=#{
              projection.projected_outputs_count
            }"
          )
        end

        unless projection.projected_outputs_count.to_i ==
               coverage.expected_outputs_count.to_i

          raise(
            "Coverage projection snapshot mismatch " \
            "height=#{height} " \
            "coverage=#{
              coverage.expected_outputs_count
            } " \
            "projection=#{
              projection.projected_outputs_count
            }"
          )
        end
      end

      def mark_processing!(coverage)
        coverage.status =
          "processing"

        coverage.started_at ||=
          Time.current

        coverage.completed_at =
          nil

        coverage.last_error =
          nil
      end

      def load_page(coverage)
        max_id =
          coverage.max_tx_output_id

        return [] if max_id.blank?

        TxOutput
          .where(
            block_height: coverage.height,
            block_hash: coverage.block_hash
          )
          .where(
            "id > ?",
            coverage.after_tx_output_id.to_i
          )
          .where(
            "id <= ?",
            max_id.to_i
          )
          .order(:id)
          .limit(batch_size)
          .pluck(
            :id,
            :address
          )
      end

      def upsert_addresses!(addresses:, height:)
        return 0 if addresses.empty?

        existing =
          Address
            .where(address: addresses)
            .pluck(:address)
            .to_set

        now =
          Time.current

        rows =
          addresses.map do |address|
            {
              address: address,
              first_seen_height: height,
              last_seen_height: height,
              tx_count: 0,
              created_at: now,
              updated_at: now
            }
          end

        Address.upsert_all(
          rows,
          unique_by:
            :index_addresses_on_address,

          on_duplicate:
            Arel.sql(
              "first_seen_height = " \
              "LEAST(" \
              "COALESCE(" \
              "addresses.first_seen_height, " \
              "EXCLUDED.first_seen_height" \
              "), " \
              "EXCLUDED.first_seen_height" \
              "), " \
              "last_seen_height = " \
              "GREATEST(" \
              "COALESCE(" \
              "addresses.last_seen_height, " \
              "EXCLUDED.last_seen_height" \
              "), " \
              "EXCLUDED.last_seen_height" \
              "), " \
              "updated_at = EXCLUDED.updated_at"
            )
        )

        addresses.count do |address|
          !existing.include?(address)
        end
      end

      def unresolved_addresses_count(addresses)
        return 0 if addresses.empty?

        Address
          .where(
            address: addresses,
            cluster_id: nil
          )
          .count
      end

      def valid_address(address)
        Clusters::Coverage::BitcoinAddressValidator
          .valid_bitcoin_address?(address)
      end

      def final_page?(coverage)
        max_id =
          coverage.max_tx_output_id.to_i

        return true if max_id.zero?

        coverage
          .after_tx_output_id
          .to_i >= max_id
      end

      def finalize!(coverage)
        audit =
          completion_audit(coverage)

        unless audit[:expected_outputs_count] ==
               coverage
                 .expected_outputs_count
                 .to_i

          raise(
            "Coverage expected output count changed " \
            "height=#{height}"
          )
        end

        unless audit[:expected_address_outputs_count] ==
               coverage
                 .expected_address_outputs_count
                 .to_i

          raise(
            "Coverage expected address output count changed " \
            "height=#{height}"
          )
        end

        unless coverage
                 .processed_outputs_count
                 .to_i ==
               audit[:expected_outputs_count]

          raise(
            "Coverage output count incomplete " \
            "height=#{height} " \
            "processed=#{
              coverage.processed_outputs_count
            } " \
            "expected=#{
              audit[:expected_outputs_count]
            }"
          )
        end

        unless coverage
                 .processed_address_outputs_count
                 .to_i ==
               audit[
                 :expected_address_outputs_count
               ]

          raise(
            "Coverage address output count incomplete " \
            "height=#{height} " \
            "processed=#{
              coverage.processed_address_outputs_count
            } " \
            "expected=#{
              audit[
                :expected_address_outputs_count
              ]
            }"
          )
        end

        if audit[:unresolved_address_outputs_count]
             .positive?

          raise(
            "Coverage unresolved outputs remain " \
            "height=#{height} " \
            "count=#{
              audit[
                :unresolved_address_outputs_count
              ]
            }"
          )
        end

        coverage.status =
          "completed"

        coverage.completed_at =
          Time.current

        coverage.last_error =
          nil

        coverage.metadata =
          coverage.metadata.to_h.merge(
            "completed_at" =>
              coverage.completed_at.iso8601(6),

            "completion_audit" =>
              audit.stringify_keys
          )
      end

      def completion_audit(coverage)
        max_id =
          coverage.max_tx_output_id.to_i

        output_addresses =
          TxOutput
            .where(
              block_height: coverage.height,
              block_hash: coverage.block_hash
            )
            .where(
              "id <= ?",
              max_id
            )
            .pluck(:address)

        valid_output_addresses =
          output_addresses.select do |address|
            valid_address(address)
          end

        cluster_by_address =
          Address
            .where(
              address:
                valid_output_addresses.uniq
            )
            .pluck(
              :address,
              :cluster_id
            )
            .to_h

        {
          expected_outputs_count:
            output_addresses.size,

          expected_address_outputs_count:
            valid_output_addresses.size,

          unresolved_address_outputs_count:
            valid_output_addresses.count do |address|
              cluster_by_address[address].blank?
            end
        }
      end

      def build_result(
        coverage:,
        page_rows:,
        distinct_addresses:,
        addresses_created:,
        singletons_created:
      )
        {
          ok: true,
          height: coverage.height,
          status: coverage.status,
          page_outputs_count:
            page_rows.size,
          page_distinct_addresses_count:
            distinct_addresses,
          page_addresses_created_count:
            addresses_created,
          page_singletons_created_count:
            singletons_created,
          after_tx_output_id:
            coverage.after_tx_output_id,
          max_tx_output_id:
            coverage.max_tx_output_id,
          processed_outputs_count:
            coverage.processed_outputs_count,
          expected_outputs_count:
            coverage.expected_outputs_count,
          processed_address_outputs_count:
            coverage.processed_address_outputs_count,
          expected_address_outputs_count:
            coverage.expected_address_outputs_count,
          pages_processed:
            coverage.pages_processed,
          completed:
            coverage.completed?
        }
      end

      def completed_result(
        coverage,
        already_completed:
      )
        {
          ok: true,
          height: coverage.height,
          status: coverage.status,
          completed: true,
          already_completed:
            already_completed,
          processed_outputs_count:
            coverage.processed_outputs_count,
          expected_outputs_count:
            coverage.expected_outputs_count
        }
      end

      def mark_failed!(error)
        coverage =
          ClusterCoverageBlock.find_by(
            height: height
          )

        return unless coverage
        return if coverage.completed?

        coverage.update_columns(
          status: "failed",
          attempts:
            coverage.attempts.to_i + 1,
          last_error:
            "#{error.class}: #{error.message}".
              first(10_000),
          metadata:
            coverage.metadata.to_h.merge(
              "last_failure_at" =>
                Time.current.iso8601(6),

              "last_failure_class" =>
                error.class.name
            ),
          updated_at:
            Time.current
        )
      rescue StandardError => mark_error
        Rails.logger.error(
          "[cluster_coverage] " \
          "failed_to_record_error " \
          "height=#{height} " \
          "error=#{mark_error.class}: " \
          "#{mark_error.message}"
        )
      end
    end
  end
end
