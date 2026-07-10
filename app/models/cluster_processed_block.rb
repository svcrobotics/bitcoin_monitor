# frozen_string_literal: true

class ClusterProcessedBlock < ApplicationRecord
  validates :height, presence: true, uniqueness: true
  validates :block_hash, presence: true
  validates :status, presence: true
end
