# frozen_string_literal: true

module Actors
  class DetectExchangeCoreFlowsForBlock
    SOURCE = "actor_profile_exchange_like"

    def self.call(block_height:)
      new(block_height: block_height).call
    end

    def initialize(block_height:)
      @block_height = block_height.to_i
      @created = 0
      @skipped = 0
    end

    def call
      cluster_ids = exchange_cluster_ids
      return empty_result("no_exchange_like_clusters") if cluster_ids.empty?

      address_map = exchange_address_map(cluster_ids)
      return empty_result("no_exchange_like_addresses") if address_map.empty?

      detect_inflows(address_map)
      detect_outflows(address_map)

      broadcast_live! if @created.positive?

      {
        ok: true,
        block_height: @block_height,
        source: SOURCE,
        exchange_like_clusters: cluster_ids.size,
        exchange_like_addresses: address_map.size,
        created: @created,
        skipped: @skipped
      }
    end

    private

    def exchange_cluster_ids
      ActorLabel
        .where(source: "actor_profile", label: "exchange_like")
        .pluck(:cluster_id)
    end

    def exchange_address_map(cluster_ids)
      Address
        .where(cluster_id: cluster_ids)
        .pluck(:address, :cluster_id)
        .to_h
    end

    def detect_inflows(address_map)
      TxOutput
        .where(block_height: @block_height, address: address_map.keys)
        .where.not(amount_btc: nil)
        .find_each do |output|

        create_event!(
          direction: "inflow",
          txid: output.txid,
          address: output.address,
          amount_btc: output.amount_btc,
          cluster_id: address_map[output.address]
        )
      end
    end

    def detect_outflows(address_map)
      TxOutput
        .where(spent_block_height: @block_height, address: address_map.keys)
        .where.not(amount_btc: nil)
        .find_each do |output|

        create_event!(
          direction: "outflow",
          txid: output.spent_txid,
          address: output.address,
          amount_btc: output.amount_btc,
          cluster_id: address_map[output.address]
        )
      end
    end

    def create_event!(direction:, txid:, address:, amount_btc:, cluster_id:)
      return if txid.blank?
      return if cluster_id.blank?

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
      event.source = SOURCE

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