# frozen_string_literal: true

module Actors
  class DetectExchangeCoreFlowsForBlock
    SOURCE = "actor_profile_exchange_like"
    ECONOMIC_ADDRESS = "__economic_exchange_flow__"

    def self.call(block_height:)
      new(block_height: block_height).call
    end

    def initialize(block_height:)
      @block_height = block_height.to_i
      @created = 0
      @skipped = 0
    end

    def call
      return empty_result("no_exchange_core_addresses") unless ExchangeCoreAddress.exists?(source: SOURCE)

      input_by_txid = exchange_inputs_by_txid
      output_by_txid = exchange_outputs_by_txid

      txids = (input_by_txid.keys + output_by_txid.keys).uniq

      txids.each do |txid|
        exchange_input_btc = input_by_txid.dig(txid, :amount).to_d
        exchange_output_btc = output_by_txid.dig(txid, :amount).to_d

        net_btc = exchange_output_btc - exchange_input_btc

        if net_btc.positive?
          create_event!(
            txid: txid,
            direction: "inflow",
            amount_btc: net_btc,
            exchange_input_btc: exchange_input_btc,
            exchange_output_btc: exchange_output_btc,
            cluster_id: output_by_txid.dig(txid, :cluster_id),
            classification: "external_inflow"
          )
        elsif net_btc.negative?
          create_event!(
            txid: txid,
            direction: "outflow",
            amount_btc: net_btc.abs,
            exchange_input_btc: exchange_input_btc,
            exchange_output_btc: exchange_output_btc,
            cluster_id: input_by_txid.dig(txid, :cluster_id),
            classification: "external_outflow"
          )
        end
      end

      broadcast_live! if @created.positive?

      {
        ok: true,
        block_height: @block_height,
        source: SOURCE,
        txids: txids.size,
        created: @created,
        skipped: @skipped
      }
    end

    private

    def exchange_inputs_by_txid
      rows =
        ClusterInput
          .joins("INNER JOIN exchange_core_addresses ON exchange_core_addresses.address = cluster_inputs.address")
          .where(spent_block_height: @block_height)
          .where(exchange_core_addresses: { source: SOURCE })
          .where.not(spent_txid: nil)
          .where.not(amount_btc: nil)
          .group("cluster_inputs.spent_txid")
          .pluck(
            "cluster_inputs.spent_txid",
            Arel.sql("SUM(cluster_inputs.amount_btc)"),
            Arel.sql("MIN(exchange_core_addresses.cluster_id)")
          )

      rows.to_h do |txid, amount, cluster_id|
        [txid, { amount: amount.to_d, cluster_id: cluster_id }]
      end
    end

    def exchange_outputs_by_txid
      rows =
        UtxoOutput
          .joins("INNER JOIN exchange_core_addresses ON exchange_core_addresses.address = utxo_outputs.address")
          .where(block_height: @block_height)
          .where(exchange_core_addresses: { source: SOURCE })
          .where.not(amount_btc: nil)
          .group("utxo_outputs.txid")
          .pluck(
            "utxo_outputs.txid",
            Arel.sql("SUM(utxo_outputs.amount_btc)"),
            Arel.sql("MIN(exchange_core_addresses.cluster_id)")
          )

      rows.to_h do |txid, amount, cluster_id|
        [txid, { amount: amount.to_d, cluster_id: cluster_id }]
      end
    end

    def create_event!(
      txid:,
      direction:,
      amount_btc:,
      exchange_input_btc:,
      exchange_output_btc:,
      cluster_id:,
      classification:
    )
      return if txid.blank?
      return if amount_btc.to_d <= 0

      event = ExchangeCoreFlowEvent.find_or_initialize_by(
        txid: txid,
        address: ECONOMIC_ADDRESS,
        direction: direction
      )

      return unless event.new_record?

      event.block_height = @block_height
      event.block_hash = block_hash
      event.cluster_id = cluster_id
      event.amount_btc = amount_btc
      event.event_time = block_time
      event.source = SOURCE
      event.metadata = {
        algorithm: "exchange_economic_netflow_v1",
        classification: classification,
        exchange_input_btc: exchange_input_btc.to_s,
        exchange_output_btc: exchange_output_btc.to_s,
        net_btc: (exchange_output_btc - exchange_input_btc).to_s
      }

      event.save!

      @created += 1
    rescue StandardError => e
      @skipped += 1

      Rails.logger.warn(
        "[exchange_core_flow] skipped " \
        "block=#{@block_height} txid=#{txid} #{e.class}: #{e.message}"
      )
    end

    def block
      @block ||= BlockBufferModel.find_by(height: @block_height)
    end

    def block_time
      block&.block_time || Time.current
    end

    def block_hash
      block&.block_hash
    end

    def broadcast_live!
      Turbo::StreamsChannel.broadcast_replace_to(
        "exchange_core_flows_live",
        target: "exchange_core_today_live",
        partial: "actors/exchange_core_flows/live",
        locals: {
          today: Dashboard::ExchangeCoreNetflowToday.call
        }
      )
    end

    def empty_result(reason)
      {
        ok: true,
        block_height: @block_height,
        source: SOURCE,
        created: 0,
        skipped: 0,
        reason: reason
      }
    end
  end
end