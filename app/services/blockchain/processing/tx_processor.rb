# frozen_string_literal: true

module Blockchain
  module Processing
    class TxProcessor
      EVENTS = Blockchain::Events::EventEmitter

      def initialize(
        logger: Rails.logger,
        prevout_resolver: nil,
        prevout_cache: nil,
        output_writer: nil,
        spent_output_writer: nil,
        write_utxos: true
      )
        @logger = logger
        @prevout_resolver =
          prevout_resolver || PrevoutResolver.new(cache: prevout_cache)

        @output_writer = output_writer || Blockchain::Utxo::OutputWriter.new
        @spent_output_writer = spent_output_writer || Blockchain::Utxo::SpentOutputWriter.new
        @write_utxos = write_utxos
      end

      def call(tx, block_height:, block_hash:, block_time: nil, tx_index: nil)
        normalized = TxNormalizer.call(tx)

        context = {
          block_height: block_height,
          block_hash: block_hash,
          block_time: block_time,
          tx_index: tx_index
        }

        emit_tx_event(normalized, context)

        inputs = resolve_inputs(normalized).compact
        real_inputs = inputs.reject { |i| i[:coinbase] }

        emit_input_events(normalized, inputs, context)
        if @write_utxos
          write_outputs(normalized, context)
          write_spent_outputs(normalized, real_inputs, context)
        end
        emit_output_events(normalized, context)
        emit_edges(normalized, real_inputs, context)

        @logger.debug("[tx_processor] processed txid=#{normalized[:txid]} height=#{block_height}")

        {
          ok: true,
          txid: normalized[:txid],
          inputs: inputs.size,
          outputs: normalized[:outputs].size,
          edges: real_inputs.size >= 2 ? 1 : 0
        }
      rescue StandardError => e
        @logger.error(
          "[tx_processor] error txid=#{tx['txid']} " \
          "height=#{block_height} #{e.class}: #{e.message}"
        )
        raise
      end

      private

      def resolve_inputs(tx)
        tx[:inputs].map do |input|
          @prevout_resolver.call(input)
        end
      end

      def emit_tx_event(tx, context)
        EVENTS.emit(
          :tx_seen,
          context.merge(txid: tx[:txid])
        )
      end

      def emit_input_events(tx, inputs, context)
        inputs.each do |input|
          next if input.nil?
          next if input[:coinbase]

          EVENTS.emit(
            :input_seen,
            context.merge(
              txid: tx[:txid],
              previous_txid: input[:txid],
              previous_vout: input[:vout],
              address: input[:address],
              amount: input[:amount]
            )
          )
        end
      end

      def emit_output_events(tx, context)
        tx[:outputs].each_with_index do |output, vout_index|
          EVENTS.emit(
            :output_created,
            context.merge(
              txid: tx[:txid],
              vout: vout_index,
              address: output[:address],
              amount: output[:value]
            )
          )
        end
      end

      def write_outputs(tx, context)
        @output_writer.call(tx, context)
      end

      def write_spent_outputs(tx, inputs, context)
        @spent_output_writer.call(tx, inputs, context)
      end

      def emit_edges(tx, inputs, context)
        addresses = inputs.map { |i| i[:address] }.compact.uniq
        return if addresses.size < 2

        EVENTS.emit(
          :multi_input_edge,
          context.merge(
            txid: tx[:txid],
            addresses: addresses
          )
        )
      end
    end
  end
end