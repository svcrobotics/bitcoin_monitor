# frozen_string_literal: true

module Clusters
  class BlockLinkWriter
    LINK_TYPE = "multi_input"

    def self.call(link_rows:)
      new(link_rows: link_rows).call
    end

    def initialize(link_rows:)
      @link_rows = Array(link_rows).compact
    end

    def call
      return 0 if link_rows.empty?

      AddressLink.insert_all(
        link_rows,
        unique_by: :idx_address_links_uniqueness
      )

      link_rows.size
    rescue ActiveRecord::RecordNotUnique
      0
    end

    private

    attr_reader :link_rows
  end
end
