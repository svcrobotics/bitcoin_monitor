# frozen_string_literal: true

class TxOutput < ApplicationRecord
  validates :txid, presence: true
  validates :vout, presence: true
  validates :txid, uniqueness: { scope: :vout }

  scope :unspent, -> { where(spent: false) }
  scope :spent, -> { where(spent: true) }
end