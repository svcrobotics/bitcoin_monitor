# frozen_string_literal: true

module Actors
  class DetectExchangeCoreFlowsForBlock
    def self.call(block_height:)
      new(block_height: block_height).call
    end

    def initialize(block_height:)
      @block_height = block_height
      @created = 0
      @skipped = 0
    end

    def call
      core_addresses = Actors::ExchangeFlowCoreAddressesQuery.call.pluck(:address)

      return empty_result if core_addresses.empty?

      detect_inflows(core_addresses)
      detect_outflows(core_addresses)

      broadcast_live! if @created.positive?

      {
        ok: true,
        block_height: @block_height,
        created: @created,
        skipped: @skipped
      }
    end

    private

    def detect_inflows(core_addresses)
      TxOutput
        .where(block_height: @block_height, address: core_addresses)
        .where.not(amount_btc: nil)
        .find_each do |output|

        create_event!(
          direction: "inflow",
          txid: output.txid,
          address: output.address,
          amount_btc: output.amount_btc,
          cluster_id: output.try(:cluster_id)
        )
      end
    end

    def detect_outflows(core_addresses)
      TxOutput
        .where(spent_block_height: @block_height, address: core_addresses)
        .where.not(amount_btc: nil)
        .find_each do |output|

        create_event!(
          direction: "outflow",
          txid: output.spent_txid,
          address: output.address,
          amount_btc: output.amount_btc,
          cluster_id: output.try(:cluster_id)
        )
      end
    end

    def create_event!(direction:, txid:, address:, amount_btc:, cluster_id:)
      event = ExchangeCoreFlowEvent.find_or_initialize_by(
        txid: txid,
        address: address,
        direction: direction
      )

      return unless event.new_record?

      event.block_height = @block_height
      event.cluster_id = cluster_id
      event.amount_btc = amount_btc
      event.event_time = Time.current
      event.source = "actor_graph_realtime"

      event.save!

      @created += 1
    rescue StandardError => e
      @skipped += 1

      Rails.logger.warn(
        "[exchange_core_flow] skipped " \
        "block=#{@block_height} #{e.class}: #{e.message}"
      )
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

    def empty_result
      {
        ok: true,
        block_height: @block_height,
        created: 0,
        skipped: 0,
        reason: "no_core_addresses"
      }
    end
  end
end