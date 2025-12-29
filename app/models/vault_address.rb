class VaultAddress < ApplicationRecord
  belongs_to :vault

  KINDS = %w[receive change].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :index, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :address, presence: true

  validates :index, uniqueness: { scope: [:vault_id, :kind] }
  validates :address, uniqueness: true
end
