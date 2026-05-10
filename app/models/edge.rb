# frozen_string_literal: true

class Edge < ApplicationRecord
  validates :txid, :address_a, :address_b, presence: true

  scope :for_address, ->(addr) {
    where("address_a = ? OR address_b = ?", addr, addr)
  }
end