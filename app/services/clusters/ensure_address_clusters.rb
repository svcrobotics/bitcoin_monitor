# frozen_string_literal: true

module Clusters
  class EnsureAddressClusters
    DEFAULT_BATCH_SIZE = 1_000

    def self.call(
      addresses:,
      mark_dirty: true
    )
      new(
        addresses: addresses,
        mark_dirty: mark_dirty
      ).call
    end

    def initialize(
      addresses:,
      mark_dirty: true,
      batch_size: ENV.fetch(
        "CLUSTER_ENSURE_ADDRESS_CLUSTERS_BATCH_SIZE",
        DEFAULT_BATCH_SIZE
      ).to_i
    )
      @addresses =
        Array(addresses)
          .compact_blank
          .uniq

      @batch_size =
        [batch_size.to_i, 1].max

      @mark_dirty =
        mark_dirty == true

      @updated = 0
      @marked = 0
      @cluster_ids = []
    end

    def call
      return empty_result if addresses.empty?

      addresses.each_slice(batch_size) do |address_batch|
        assign_batch!(address_batch)
      end

      mark_dirty_clusters! if mark_dirty

      {
        ok: true,
        updated: updated,
        marked: marked,
        clusters: cluster_ids.uniq.size
      }
    end

    private

    attr_reader(
      :addresses,
      :batch_size,
      :mark_dirty,
      :updated,
      :marked,
      :cluster_ids
    )

    def assign_batch!(address_batch)
      address_rows =
        Address
          .where(
            address: address_batch,
            cluster_id: nil
          )
          .order(:id)
          .pluck(:id, :address)

      return if address_rows.empty?

      now = Time.current

      reserved_cluster_ids =
        reserve_cluster_ids(
          address_rows.size
        )

      assignments =
        address_rows
          .zip(reserved_cluster_ids)
          .map do |(address_id, _address), cluster_id|
            [
              address_id.to_i,
              cluster_id.to_i
            ]
          end

      used_cluster_ids = []

      ApplicationRecord.transaction do
        insert_reserved_clusters!(
          cluster_ids: reserved_cluster_ids,
          now: now
        )

        used_cluster_ids =
          assign_clusters_to_addresses!(
            assignments: assignments,
            now: now
          )

        refresh_cluster_stats!(
          cluster_ids: used_cluster_ids,
          now: now
        )

        remove_unused_clusters!(
          reserved_cluster_ids:
            reserved_cluster_ids,

          used_cluster_ids:
            used_cluster_ids
        )
      end

      @cluster_ids.concat(
        used_cluster_ids
      )

      @updated +=
        used_cluster_ids.size
    end

    def reserve_cluster_ids(count)
      return [] if count.to_i <= 0

      connection =
        ActiveRecord::Base.connection

      table_name =
        connection.quote(
          Cluster.table_name
        )

      sql = <<~SQL.squish
        SELECT nextval(
          pg_get_serial_sequence(
            #{table_name},
            'id'
          )
        )
        FROM generate_series(
          1,
          #{count.to_i}
        )
      SQL

      connection
        .select_values(sql)
        .map(&:to_i)
    end

    def insert_reserved_clusters!(
      cluster_ids:,
      now:
    )
      return if cluster_ids.empty?

      rows =
        cluster_ids.map do |cluster_id|
          {
            id: cluster_id,
            composition_version: 1,
            created_at: now,
            updated_at: now
          }
        end

      Cluster.insert_all!(rows)
    end

    def assign_clusters_to_addresses!(
      assignments:,
      now:
    )
      return [] if assignments.empty?

      connection =
        ActiveRecord::Base.connection

      values_sql =
        assignments.map do |address_id, cluster_id|
          "(#{Integer(address_id)}, #{Integer(cluster_id)})"
        end.join(", ")

      addresses_table =
        connection.quote_table_name(
          Address.table_name
        )

      id_column =
        connection.quote_column_name("id")

      cluster_id_column =
        connection.quote_column_name(
          "cluster_id"
        )

      updated_at_column =
        connection.quote_column_name(
          "updated_at"
        )

      sql = <<~SQL
        UPDATE #{addresses_table} AS target

        SET
          #{cluster_id_column} =
            source.cluster_id,

          #{updated_at_column} =
            #{connection.quote(now)}

        FROM (
          VALUES #{values_sql}
        ) AS source(
          address_id,
          cluster_id
        )

        WHERE target.#{id_column} =
              source.address_id

          AND target.#{cluster_id_column}
              IS NULL

        RETURNING
          target.#{cluster_id_column}
      SQL

      connection
        .select_values(sql)
        .map(&:to_i)
    end

    def refresh_cluster_stats!(
      cluster_ids:,
      now:
    )
      ids =
        Array(cluster_ids)
          .compact
          .map(&:to_i)
          .reject(&:zero?)
          .uniq

      return if ids.empty?

      connection =
        ActiveRecord::Base.connection

      clusters_table =
        connection.quote_table_name(
          Cluster.table_name
        )

      addresses_table =
        connection.quote_table_name(
          Address.table_name
        )

      ids_sql =
        ids
          .map { |id| Integer(id) }
          .join(", ")

      sql = <<~SQL
        UPDATE #{clusters_table} AS target

        SET
          address_count =
            source.address_count,

          total_received_sats =
            source.total_received_sats,

          total_sent_sats =
            source.total_sent_sats,

          first_seen_height =
            source.first_seen_height,

          last_seen_height =
            source.last_seen_height,

          updated_at =
            #{connection.quote(now)}

        FROM (
          SELECT
            cluster_id,

            COUNT(*)::integer
              AS address_count,

            COALESCE(
              SUM(total_received_sats),
              0
            )::bigint
              AS total_received_sats,

            COALESCE(
              SUM(total_sent_sats),
              0
            )::bigint
              AS total_sent_sats,

            MIN(first_seen_height)
              AS first_seen_height,

            MAX(last_seen_height)
              AS last_seen_height

          FROM #{addresses_table}

          WHERE cluster_id IN (
            #{ids_sql}
          )

          GROUP BY cluster_id
        ) AS source

        WHERE target.id =
              source.cluster_id
      SQL

      connection.execute(sql)
    end

    def remove_unused_clusters!(
      reserved_cluster_ids:,
      used_cluster_ids:
    )
      unused_cluster_ids =
        reserved_cluster_ids
          .map(&:to_i) -
        used_cluster_ids
          .map(&:to_i)

      return if unused_cluster_ids.empty?

      Cluster
        .where(id: unused_cluster_ids)
        .delete_all
    end

    def mark_dirty_clusters!
      cluster_ids.uniq.each do |cluster_id|
        ActorProfiles::DirtyMarker.mark(
          cluster_id
        )

        @marked += 1
      end
    end

    def empty_result
      {
        ok: true,
        updated: 0,
        marked: 0,
        clusters: 0
      }
    end


  end
end
