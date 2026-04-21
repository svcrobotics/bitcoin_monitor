# frozen_string_literal: true

module ExchangeLike
  class AddressUpserter
    Result = Struct.new(
      :upsert_rows_count,
      keyword_init: true
    )

    def initialize(source_name:)
      @source_name = source_name
    end

    def call(rows)
      return Result.new(upsert_rows_count: 0) if rows.empty?

      now = Time.current
      addresses = rows.map { |row| row[:address] }

      existing_by_address =
        ExchangeAddress
          .where(address: addresses)
          .index_by(&:address)

      upsert_rows = rows.map do |row|
        existing = existing_by_address[row[:address]]

        {
          address: row[:address],
          source: merged_source(existing, row[:source]),
          occurrences: merged_occurrences(existing, row[:occurrences_inc]),
          confidence: merged_confidence(existing, row[:confidence_inc]),
          first_seen_at: [existing&.first_seen_at, row[:seen_at_min]].compact.min,
          last_seen_at:  [existing&.last_seen_at,  row[:seen_at_max]].compact.max,
          created_at: existing&.created_at || now,
          updated_at: now
        }
      end

      ExchangeAddress.upsert_all(
        upsert_rows,
        unique_by: :index_exchange_addresses_on_address
      )

      Result.new(upsert_rows_count: upsert_rows.size)
    end

    private

    def merged_source(existing, incoming_source)
      return incoming_source if existing.blank? || existing.source.blank?

      parts = existing.source.to_s.split(",").map(&:strip).reject(&:blank?)
      parts << incoming_source unless parts.include?(incoming_source)
      parts.join(",")
    end

    def merged_occurrences(existing, occurrences_inc)
      if existing
        existing.occurrences.to_i + occurrences_inc.to_i
      else
        occurrences_inc.to_i
      end
    end

    def merged_confidence(existing, confidence_inc)
      current = existing ? existing.confidence.to_i : 0
      [100, current + confidence_inc.to_i].min
    end
  end
end