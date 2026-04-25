# frozen_string_literal: true

module Clusters
  class AddressWriter
    def self.call(grouped_inputs:, height:)
      new(grouped_inputs: grouped_inputs, height: height).call
    end

    def initialize(grouped_inputs:, height:)
      @grouped_inputs = grouped_inputs
      @height = height.to_i
    end

    def call
      addresses = grouped_inputs.keys

      existing_records = Address.where(address: addresses).index_by(&:address)

      missing_addresses = addresses - existing_records.keys

      missing_addresses.each do |addr|
        existing_records[addr] = create_address!(addr)
      end

      records = addresses.map { |addr| existing_records.fetch(addr) }

      assign_input_stats!(records)

      records
    end

    private

    attr_reader :grouped_inputs, :height

    def create_address!(addr)
      Address.create_or_find_by!(address: addr) do |record|
        record.first_seen_height = height
        record.last_seen_height = height
      end
    rescue ActiveRecord::RecordInvalid
      found = Address.find_by(address: addr)
      return found if found.present?

      raise "AddressWriter failed address=#{addr.inspect} height=#{height}"
    end

    def assign_input_stats!(records)
      records.each do |record|
        input_data = grouped_inputs.fetch(record.address)
        sent_sats = input_data[:total_value_sats].to_i

        record.update!(
          first_seen_height: min_present(record.first_seen_height, height),
          last_seen_height: max_present(record.last_seen_height, height),
          total_sent_sats: record.total_sent_sats.to_i + sent_sats,
          tx_count: record.tx_count.to_i + 1
        )
      end
    end

    def min_present(a, b)
      return b if a.blank?
      [a, b].min
    end

    def max_present(a, b)
      return b if a.blank?
      [a, b].max
    end
  end
end
