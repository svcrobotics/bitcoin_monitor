# app/services/address_flow_stats/backfill_block_range.rb
module AddressFlowStats
  class BackfillBlockRange
    def self.call(from_height:, to_height:)
      new(from_height:, to_height:).call
    end

    def initialize(from_height:, to_height:)
      @from_height = from_height
      @to_height = to_height
    end

    def call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      puts "[AddressFlowStats] range=#{@from_height}..#{@to_height}"

      sql = <<~SQL
        WITH stats AS (
          SELECT
            address,
            SUM(amount_btc) AS received_btc,
            SUM(
              CASE
                WHEN spent THEN amount_btc
                ELSE 0
              END
            ) AS sent_btc,
            COUNT(DISTINCT txid) AS tx_count,
            MIN(block_time) AS first_seen_at,
            MAX(block_time) AS last_seen_at
          FROM tx_outputs
          WHERE block_height BETWEEN #{@from_height} AND #{@to_height}
            AND address IS NOT NULL
          GROUP BY address
        )
        INSERT INTO address_flow_stats (
          address,
          received_btc,
          sent_btc,
          net_btc,
          tx_count,
          first_seen_at,
          last_seen_at,
          metadata,
          created_at,
          updated_at
        )
        SELECT
          address,
          received_btc,
          sent_btc,
          received_btc - sent_btc,
          tx_count,
          first_seen_at,
          last_seen_at,
          jsonb_build_object(
            'source', 'block_range_backfill',
            'from_height', #{@from_height},
            'to_height', #{@to_height}
          ),
          NOW(),
          NOW()
        FROM stats
        ON CONFLICT (address)
        DO UPDATE SET
          received_btc = address_flow_stats.received_btc + EXCLUDED.received_btc,
          sent_btc = address_flow_stats.sent_btc + EXCLUDED.sent_btc,
          net_btc = (
            address_flow_stats.received_btc + EXCLUDED.received_btc
          ) - (
            address_flow_stats.sent_btc + EXCLUDED.sent_btc
          ),
          tx_count = address_flow_stats.tx_count + EXCLUDED.tx_count,
          first_seen_at = LEAST(address_flow_stats.first_seen_at, EXCLUDED.first_seen_at),
          last_seen_at = GREATEST(address_flow_stats.last_seen_at, EXCLUDED.last_seen_at),
          updated_at = NOW()
      SQL

      ActiveRecord::Base.connection.execute(sql)

      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      result = {
        from_height: @from_height,
        to_height: @to_height,
        duration_s: duration.round(2),
        total_stats: AddressFlowStat.count
      }

      puts result

      result
    end
  end
end
