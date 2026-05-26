# app/services/actor_profiles/write_deltas.rb
# frozen_string_literal: true

module ActorProfiles
  class WriteDeltas
    def self.call(outputs:, direction:)
      new(outputs: outputs, direction: direction).call
    end

    def initialize(outputs:, direction:)
      @outputs = Array(outputs).compact
      @direction = direction.to_sym

      raise ArgumentError, "invalid direction #{@direction.inspect}" unless %i[received spent].include?(@direction)
    end

    def call
      grouped = grouped_outputs
      return { deltas: 0, clusters: 0 } if grouped.empty?

      address_map = Address
        .where(address: grouped.keys)
        .where.not(cluster_id: nil)
        .pluck(:address, :cluster_id)
        .to_h

      rows = build_rows(grouped, address_map)
      return { deltas: 0, clusters: 0 } if rows.empty?

      ActorProfileDelta.transaction do
        rows.each_slice(1_000) do |slice|
          ActorProfileDelta.create!(slice)
        end
      end

      cluster_ids = rows.map { |r| r[:cluster_id] }.uniq
      cluster_ids.each { |cluster_id| ActorProfiles::DirtyMarker.mark(cluster_id) }

      {
        deltas: rows.size,
        clusters: cluster_ids.size
      }
    end

    private

    def grouped_outputs
      @outputs
        .select { |o| o.address.present? && block_height_for(o).positive? }
        .group_by(&:address)
    end

    def build_rows(grouped, address_map)
      now = Time.current

      grouped.flat_map do |address, outputs|
        cluster_id = address_map[address]
        next [] if cluster_id.blank?

        outputs
          .group_by { |o| block_height_for(o) }
          .map do |block_height, block_outputs|
            amount_btc = block_outputs.sum { |o| o.amount_btc.to_d }
            tx_count = tx_count_for(block_outputs)
            times = times_for(block_outputs)

            {
              cluster_id: cluster_id,
              block_height: block_height,
              received_btc_delta: received_delta(amount_btc),
              sent_btc_delta: sent_delta(amount_btc),
              net_btc_delta: net_delta(amount_btc),
              tx_count_delta: tx_count,
              first_seen_at: times.min,
              last_seen_at: times.max,
              processed_at: nil,
              created_at: now,
              updated_at: now
            }
          end
      end
    end

    def block_height_for(output)
      if @direction == :spent
        output.spent_block_height.to_i
      else
        output.block_height.to_i
      end
    end

    def tx_count_for(outputs)
      if @direction == :spent
        outputs.map(&:spent_txid).compact.uniq.size
      else
        outputs.map(&:txid).compact.uniq.size
      end
    end

    def received_delta(amount_btc)
      @direction == :received ? amount_btc : 0
    end

    def sent_delta(amount_btc)
      @direction == :spent ? amount_btc : 0
    end

    def net_delta(amount_btc)
      @direction == :received ? amount_btc : -amount_btc
    end

    def times_for(outputs)
      if @direction == :spent
        outputs.map(&:updated_at).compact
      else
        outputs.map(&:block_time).compact
      end
    end
  end
end

