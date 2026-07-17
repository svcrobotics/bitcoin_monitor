# frozen_string_literal: true

require "bigdecimal"

module AddressSpendStats
  class ClusterAggregate
    SATOSHI =
      BigDecimal("100000000")

    class ProjectionNotReady < StandardError
      attr_reader(
        :required_height,
        :projection_tip,
        :next_record_height
      )

      def initialize(
        required_height:,
        projection_tip:,
        next_record_height:
      )
        @required_height =
          required_height.to_i

        @projection_tip =
          projection_tip.to_i

        @next_record_height =
          next_record_height&.to_i

        super(
          "AddressSpend projection is not ready "           "required_height=#{@required_height} "           "projection_tip=#{@projection_tip} "           "next_record_height=#{@next_record_height}"
        )
      end
    end

    def self.call(
      cluster_id:,
      required_height:
    )
      new(
        cluster_id: cluster_id,
        required_height:
          required_height
      ).call
    end

    def initialize(
      cluster_id:,
      required_height:
    )
      @cluster_id =
        Integer(cluster_id)

      @required_height =
        Integer(required_height)

      raise(
        ArgumentError,
        "cluster_id must be positive"
      ) unless @cluster_id.positive?

      raise(
        ArgumentError,
        "required_height must be positive"
      ) unless @required_height.positive?
    end

    def call
      ensure_projection_ready!

      row =
        connection.select_one(
          aggregate_sql
        ) || {}

      total_sent_sats =
        row[
          "total_sent_sats"
        ].to_i

      {
        cluster_id:
          cluster_id,

        required_height:
          required_height,

        projection_tip:
          projection_tip,

        total_sent_sats:
          total_sent_sats,

        total_sent_btc:
          BigDecimal(
            total_sent_sats.to_s
          ) / SATOSHI,

        spent_inputs_count:
          row[
            "spent_inputs_count"
          ].to_i,

        first_spent_height:
          nullable_integer(
            row[
              "first_spent_height"
            ]
          ),

        last_spent_height:
          nullable_integer(
            row[
              "last_spent_height"
            ]
          ),

        addresses_with_spend_count:
          row[
            "addresses_with_spend_count"
          ].to_i
      }
    end

    private

    attr_reader(
      :cluster_id,
      :required_height
    )

    def ensure_projection_ready!
      next_height =
        AddressSpendStats::
          NextRecord
          .call
          &.height
          &.to_i

      ready =
        projection_tip >=
          required_height &&
        (
          next_height.nil? ||
          next_height >
            required_height
        )

      return if ready

      raise ProjectionNotReady.new(
        required_height:
          required_height,

        projection_tip:
          projection_tip,

        next_record_height:
          next_height
      )
    end

    def projection_tip
      @projection_tip ||=
        AddressSpendProjectionBlock
          .where(
            status: "completed"
          )
          .maximum(
            :height
          )
          .to_i
    end

    def aggregate_sql
      stats_table =
        connection.quote_table_name(
          AddressSpendStat.table_name
        )

      addresses_table =
        connection.quote_table_name(
          Address.table_name
        )

      <<~SQL
        SELECT
          COALESCE(
            SUM(
              spend_stats.total_sent_sats
            ),
            0
          ) AS total_sent_sats,

          COALESCE(
            SUM(
              spend_stats.spent_inputs_count
            ),
            0
          ) AS spent_inputs_count,

          MIN(
            spend_stats.first_spent_height
          ) AS first_spent_height,

          MAX(
            spend_stats.last_spent_height
          ) AS last_spent_height,

          COUNT(*) AS
            addresses_with_spend_count

        FROM #{stats_table}
          AS spend_stats

        INNER JOIN #{addresses_table}
          AS addresses

          ON addresses.address =
             spend_stats.address

        WHERE addresses.cluster_id =
              #{cluster_id}
      SQL
    end

    def connection
      ApplicationRecord.connection
    end

    def nullable_integer(value)
      return nil if value.nil?

      value.to_i
    end
  end
end
