# app/services/address_flow_stats/apply_outputs.rb
# frozen_string_literal: true

module AddressFlowStats
  class ApplyOutputs
    def self.call(outputs:)
      new(outputs).call
    end

    def initialize(outputs)
      @outputs = Array(outputs).compact
    end

    def call
      with_deadlock_retry do
        rows = grouped_rows
        return { addresses: 0 } if rows.empty?

        AddressFlowStat.upsert_all(
          rows,
          unique_by: :index_address_flow_stats_on_address
        )

        ActorProfiles::WriteDeltas.call(
          outputs: @outputs,
          direction: :received
        )

        { addresses: rows.size }
      end
    end

    private

    def grouped_rows
      now = Time.current
      grouped = @outputs
        .select { |o| o.address.present? }
        .group_by(&:address)

      return [] if grouped.empty?

      existing_by_address = AddressFlowStat
        .where(address: grouped.keys)
        .index_by(&:address)

      grouped.map do |address, outputs|
        received_btc = outputs.sum { |o| o.amount_btc.to_d }
        tx_count = outputs.map(&:txid).uniq.size
        times = outputs.map(&:block_time).compact

        existing = existing_by_address[address]

        old_received = existing&.received_btc.to_d
        old_sent = existing&.sent_btc.to_d
        old_tx_count = existing&.tx_count.to_i

        new_received = old_received + received_btc

        {
          address: address,
          received_btc: new_received,
          sent_btc: old_sent,
          net_btc: new_received - old_sent,
          tx_count: old_tx_count + tx_count,
          first_seen_at: [existing&.first_seen_at, times.min].compact.min,
          last_seen_at: [existing&.last_seen_at, times.max].compact.max,
          metadata: { source: "layer1_live_outputs" },
          created_at: existing&.created_at || now,
          updated_at: now
        }
      end
    end

    def with_deadlock_retry(max_attempts: 3)
      attempts = 0

      begin
        attempts += 1
        yield
      rescue ActiveRecord::Deadlocked => e
        raise if attempts >= max_attempts

        sleep(0.2 * attempts)
        retry
      end
    end
  end
end