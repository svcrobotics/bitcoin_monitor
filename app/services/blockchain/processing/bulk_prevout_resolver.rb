# frozen_string_literal: true

module Blockchain
  module Processing
    class BulkPrevoutResolver
      DEFAULT_BATCH_SIZE = 500

      def initialize(batch_size: DEFAULT_BATCH_SIZE, logger: Rails.logger)
        @batch_size = batch_size
        @logger = logger
      end

      def call(transactions)
        started_at = monotonic_ms

        keys = extract_keys(transactions)
        return {} if keys.empty?

        result = {}

        keys.each_slice(@batch_size) do |slice|
          resolve_slice(slice, result)
        end

        duration_ms = monotonic_ms - started_at

        @logger.info(
          "[bulk_prevout_resolver] keys=#{keys.size} " \
          "resolved=#{result.size} duration_ms=#{duration_ms}"
        )

        result
      end

      private

      def resolve_slice(slice, result)
        values_sql =
          slice.map do |txid, vout|
            ActiveRecord::Base.sanitize_sql_array(["(?, ?)", txid, vout])
          end.join(",")

        sql = <<~SQL.squish
          SELECT
            txo.txid,
            txo.vout
          FROM tx_outputs txo
          INNER JOIN (
            VALUES #{values_sql}
          ) AS prevouts(txid, vout)
            ON txo.txid = prevouts.txid
           AND txo.vout = prevouts.vout
        SQL

        rows = ActiveRecord::Base.connection.exec_query(sql)

        rows.each do |row|
          key = [row["txid"], row["vout"].to_i]

          result[key] = true
        end
      end

      def extract_keys(transactions)
        transactions.flat_map do |tx|
          inputs = tx[:inputs] || tx["vin"] || []

          inputs.filter_map do |input|
            next if input[:coinbase] || input["coinbase"]

            txid = input[:txid] || input["txid"]
            vout = input[:vout] || input["vout"]

            next if txid.blank?
            next unless vout.is_a?(Integer)

            [txid, vout]
          end
        end.uniq
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end
    end
  end
end