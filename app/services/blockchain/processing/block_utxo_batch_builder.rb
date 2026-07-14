# frozen_string_literal: true

module Blockchain
  module Processing
    class BlockUtxoBatchBuilder
      def initialize(prevout_cache:, logger: Rails.logger, strict_prevout: false)
        @prevout_cache = prevout_cache || {}
        @logger = logger
        @strict_prevout = strict_prevout
      end

      def call(block, block_buffer)
        now = Time.current
        block_time = normalize_time(block["time"])

        output_rows = []
        spent_rows = []

        tx_count = 0
        input_count = 0
        output_count = 0
        prevout_found_count = 0
        prevout_missing_count = 0

        block.fetch("tx").each_with_index do |raw_tx, tx_index|
          txid = raw_tx["txid"]
          outputs = raw_tx["vout"] || []
          inputs = raw_tx["vin"] || []

          tx_count += 1
          input_count += inputs.size
          output_count += outputs.size

          outputs.each_with_index do |output, fallback_vout|
            vout = output["n"] || fallback_vout
            address = extract_address(output)
            value = output["value"]

            output_rows << {
              txid: txid,
              vout: vout,
              address: address,
              amount_btc: value,
              block_height: block_buffer.height,
              block_hash: block_buffer.block_hash,
              block_time: block_time,
              created_at: now,
              updated_at: now
            }
          end

          inputs.each do |input|
            next if input["coinbase"].present?

            previous_txid = input["txid"]
            previous_vout = input["vout"]

            next if previous_txid.blank?
            next unless previous_vout.is_a?(Integer)

            prevout = extract_prevout(input, previous_txid, previous_vout)

            if prevout.blank?
              prevout_missing_count += 1

              if @strict_prevout
                raise(
                  "missing prevout height=#{block_buffer.height} " \
                  "txid=#{txid} input_txid=#{previous_txid} input_vout=#{previous_vout}"
                )
              end

              next
            end

            prevout_found_count += 1

            spent_rows << {
              txid: previous_txid,
              vout: previous_vout,
              spent: true,
              spent_txid: txid,
              spent_block_height: block_buffer.height,

              # Ces champs supplémentaires ne cassent pas l'ancien flusher.
              # Ils servent au mode strict pour construire ClusterInput même si
              # le prevout n'existe pas encore dans notre PostgreSQL local.
              prevout_address: extract_address(prevout),
              prevout_amount_btc: prevout["value"],
              prevout_block_height: prevout["height"],
              prevout_generated: prevout["generated"],

              updated_at: now
            }
          end
        end

        result = {
          output_rows: output_rows,
          spent_rows: spent_rows,
          tx_count: tx_count,
          input_count: input_count,
          output_count: output_count,
          prevout_found_count: prevout_found_count,
          prevout_missing_count: prevout_missing_count
        }

        @logger.info(
          "[block_utxo_batch_builder] height=#{block_buffer.height} " \
          "txs=#{tx_count} inputs=#{input_count} outputs=#{output_count} " \
          "output_rows=#{output_rows.size} spent_rows=#{spent_rows.size} " \
          "prevout_found=#{prevout_found_count} prevout_missing=#{prevout_missing_count} " \
          "strict_prevout=#{@strict_prevout}"
        )

        result
      end

      private

      def normalize_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return Time.at(value).in_time_zone if value.present?

        nil
      end

      def extract_prevout(input, previous_txid, previous_vout)
        # Bitcoin Core getblock verbosity 3 fournit directement vin.prevout.
        return input["prevout"] if input["prevout"].present?

        # Compatibilité avec l'ancien pipeline.
        @prevout_cache[[previous_txid, previous_vout]]
      end

      def extract_address(output_or_prevout)
        script = output_or_prevout["scriptPubKey"] || {}

        return script["address"] if script["address"].present?
        return script["addresses"].first if script["addresses"].present?

        nil
      end
    end
  end
end
