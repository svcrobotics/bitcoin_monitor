# frozen_string_literal: true

module Actors
  class RebuildExchangeCoreAddresses
    SOURCE =
      ActorLabels::StrictWriter::SOURCE

    INSERT_BATCH_SIZE = 2_000

    def self.call(
      dry_run: true
    )
      new(
        dry_run: dry_run
      ).call
    end

    def initialize(
      dry_run:
    )
      @dry_run =
        dry_run == true
    end

    def call
      cluster_ids =
        strict_cluster_ids

      if cluster_ids.empty?
        return failure(
          reason:
            "no_strict_exchange_like_clusters"
        )
      end

      counts_by_cluster =
        address_counts_by_cluster(
          cluster_ids
        )

      missing_cluster_ids =
        cluster_ids.reject do |cluster_id|
          counts_by_cluster[
            cluster_id
          ].to_i.positive?
        end

      if missing_cluster_ids.any?
        return failure(
          reason:
            "strict_exchange_clusters_without_addresses",

          cluster_ids:
            cluster_ids,

          missing_cluster_ids:
            missing_cluster_ids
        )
      end

      rows =
        address_rows(
          cluster_ids
        )

      if rows.empty?
        return failure(
          reason:
            "no_exchange_core_addresses",

          cluster_ids:
            cluster_ids
        )
      end

      preview =
        build_result(
          status:
            dry_run ?
              "preview" :
              "pending",

          cluster_ids:
            cluster_ids,

          rows:
            rows,

          counts_by_cluster:
            counts_by_cluster,

          previous_count:
            ExchangeCoreAddress.count,

          inserted_count:
            0
        )

      return preview if dry_run

      rebuild!(
        cluster_ids:
          cluster_ids,

        rows:
          rows,

        counts_by_cluster:
          counts_by_cluster
      )
    rescue StandardError => error
      Rails.logger.error(
        "[rebuild_exchange_core_addresses] " \
        "#{error.class}: #{error.message}"
      )

      {
        ok: false,
        status: "failed",
        source: SOURCE,
        error_class: error.class.name,
        error_message: error.message
      }
    end

    private

    attr_reader :dry_run

    def strict_cluster_ids
      Actors::StrictExchangeLikeQuery
        .call
        .distinct
        .pluck(:cluster_id)
        .compact
        .uniq
        .sort
    end

    def address_scope(
      cluster_ids
    )
      Address
        .where(
          cluster_id: cluster_ids
        )
        .where.not(
          address: [nil, ""]
        )
    end

    def address_counts_by_cluster(
      cluster_ids
    )
      address_scope(
        cluster_ids
      )
        .group(:cluster_id)
        .count
    end

    def address_rows(
      cluster_ids
    )
      address_scope(
        cluster_ids
      )
        .distinct
        .pluck(
          :address,
          :cluster_id
        )
    end

    def rebuild!(
      cluster_ids:,
      rows:,
      counts_by_cluster:
    )
      previous_count =
        ExchangeCoreAddress.count

      inserted_count = 0

      ExchangeCoreAddress.transaction do
        ExchangeCoreAddress.delete_all

        now =
          Time.current

        rows.each_slice(
          INSERT_BATCH_SIZE
        ) do |batch|
          payload =
            batch.map do |address,
                          cluster_id|
              {
                address:
                  address,

                cluster_id:
                  cluster_id,

                source:
                  SOURCE,

                created_at:
                  now,

                updated_at:
                  now
              }
            end

          ExchangeCoreAddress.insert_all!(
            payload
          )

          inserted_count +=
            payload.size
        end

        verify_rebuild!(
          expected_rows:
            rows,

          expected_cluster_ids:
            cluster_ids
        )
      end

      build_result(
        status:
          "rebuilt",

        cluster_ids:
          cluster_ids,

        rows:
          rows,

        counts_by_cluster:
          counts_by_cluster,

        previous_count:
          previous_count,

        inserted_count:
          inserted_count
      )
    end

    def verify_rebuild!(
      expected_rows:,
      expected_cluster_ids:
    )
      actual_count =
        ExchangeCoreAddress.count

      expected_count =
        expected_rows.size

      unless actual_count ==
             expected_count
        raise(
          "exchange_core_addresses count mismatch " \
          "expected=#{expected_count} " \
          "actual=#{actual_count}"
        )
      end

      invalid_source_count =
        ExchangeCoreAddress
          .where.not(
            source: SOURCE
          )
          .count

      if invalid_source_count.positive?
        raise(
          "exchange_core_addresses invalid source " \
          "count=#{invalid_source_count}"
        )
      end

      actual_cluster_ids =
        ExchangeCoreAddress
          .distinct
          .pluck(:cluster_id)
          .sort

      unless actual_cluster_ids ==
             expected_cluster_ids.sort
        raise(
          "exchange_core_addresses cluster mismatch " \
          "expected=#{expected_cluster_ids.sort.inspect} " \
          "actual=#{actual_cluster_ids.inspect}"
        )
      end
    end

    def build_result(
      status:,
      cluster_ids:,
      rows:,
      counts_by_cluster:,
      previous_count:,
      inserted_count:
    )
      {
        ok: true,
        status: status,
        dry_run: dry_run,
        source: SOURCE,

        clusters_count:
          cluster_ids.size,

        cluster_ids:
          cluster_ids,

        addresses_count:
          rows.size,

        addresses_by_cluster:
          counts_by_cluster.sort.to_h,

        previous_count:
          previous_count,

        inserted_count:
          inserted_count
      }
    end

    def failure(
      reason:,
      cluster_ids: [],
      missing_cluster_ids: []
    )
      {
        ok: false,
        status: "refused",
        dry_run: dry_run,
        source: SOURCE,
        reason: reason,
        cluster_ids: cluster_ids,
        missing_cluster_ids:
          missing_cluster_ids,

        preserved_existing_rows:
          ExchangeCoreAddress.count
      }
    end
  end
end
