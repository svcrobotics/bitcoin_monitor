# frozen_string_literal: true
require "set"

module Clusters
  class LinkWriter
    LINK_TYPE = "multi_input"

    def self.call(address_records:, txid:, height:)
      new(
        address_records: address_records,
        txid: txid,
        height: height
      ).call
    end

    def initialize(address_records:, txid:, height:)
      @address_records = Array(address_records).compact
      @txid = txid.to_s
      @height = height.to_i
    end

    def call
      records = address_records.sort_by(&:id)
      return 0 if records.size < 2

      rows = build_link_rows(records)
      return 0 if rows.empty?

      existing_pairs = existing_pairs_for(rows)

      new_rows = rows.reject do |row|
        existing_pairs.include?([row[:address_a_id], row[:address_b_id]])
      end

      return 0 if new_rows.empty?

      AddressLink.insert_all(
        new_rows,
        unique_by: :idx_address_links_uniqueness
      )

      new_rows.size
    end

    private

    attr_reader :address_records, :txid, :height

    def build_link_rows(records)
      now = Time.current
      pivot = records.first

      records.drop(1).map do |other|
        id_a, id_b = [pivot.id, other.id].sort

        {
          address_a_id: id_a,
          address_b_id: id_b,
          link_type: LINK_TYPE,
          txid: txid,
          block_height: height,
          created_at: now,
          updated_at: now
        }
      end
    end

    def existing_pairs_for(rows)
      pairs = rows.map { |r| [r[:address_a_id], r[:address_b_id]] }

      AddressLink
        .where(txid: txid, link_type: LINK_TYPE)
        .where(address_a_id: pairs.map(&:first), address_b_id: pairs.map(&:second))
        .pluck(:address_a_id, :address_b_id)
        .to_set
    end
  end
end