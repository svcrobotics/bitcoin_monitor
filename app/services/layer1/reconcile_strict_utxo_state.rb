# frozen_string_literal: true

module Layer1
  class ReconcileStrictUtxoState
    def self.call(height:)
      new(height: height).call
    end

    def initialize(height:)
      @height = height.to_i
    end

    def call
      {
        ok: true,
        height: @height,
        stale_utxos_deleted: delete_stale_utxos!
      }
    end

    private

    def delete_stale_utxos!
      sql = ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          DELETE FROM utxo_outputs AS u
          USING cluster_inputs AS ci
          WHERE u.txid = ci.txid
            AND u.vout = ci.vout
            AND ci.spent_block_height = ?
          RETURNING u.id
        SQL
        @height
      ])

      ActiveRecord::Base.connection.exec_query(sql).rows.size
    end
  end
end
