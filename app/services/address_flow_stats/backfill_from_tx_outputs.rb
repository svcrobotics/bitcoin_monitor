# app/services/address_flow_stats/backfill_from_tx_outputs.rb
module AddressFlowStats
  class BackfillFromTxOutputs
    DEFAULT_LIMIT = 10_000

    def self.call(limit: DEFAULT_LIMIT)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit = limit
    end

    def call
      sql = sanitize_sql([<<~SQL, @limit])
        WITH batch AS (
          SELECT address
          FROM tx_outputs
          WHERE address IS NOT NULL
          GROUP BY address
          ORDER BY MAX(block_height) DESC
          LIMIT ?
        ),
        stats AS (
          SELECT
            tx_outputs.address,
            SUM(tx_outputs.amount_btc) AS received_btc,
            SUM(CASE WHEN tx_outputs.spent THEN tx_outputs.amount_btc ELSE 0 END) AS sent_btc,
            COUNT(DISTINCT tx_outputs.txid) AS tx_count,
            MIN(tx_outputs.block_time) AS first_seen_at,
            MAX(tx_outputs.block_time) AS last_seen_at
          FROM tx_outputs
          INNER JOIN batch ON batch.address = tx_outputs.address
          GROUP BY tx_outputs.address
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
          '{"source":"tx_outputs_backfill"}'::jsonb,
          NOW(),
          NOW()
        FROM stats
        ON CONFLICT (address)
        DO UPDATE SET
          received_btc = EXCLUDED.received_btc,
          sent_btc = EXCLUDED.sent_btc,
          net_btc = EXCLUDED.net_btc,
          tx_count = EXCLUDED.tx_count,
          first_seen_at = EXCLUDED.first_seen_at,
          last_seen_at = EXCLUDED.last_seen_at,
          metadata = EXCLUDED.metadata,
          updated_at = NOW()
      SQL

      result = ActiveRecord::Base.connection.execute(sql)

      {
        limit: @limit,
        rows: result.cmd_tuples,
        total: AddressFlowStat.count
      }
    end

    private

    def sanitize_sql(args)
      ActiveRecord::Base.send(:sanitize_sql_array, args)
    end
  end
end
