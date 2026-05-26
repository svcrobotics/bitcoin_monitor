# frozen_string_literal: true

class ActorProfileDelta < ApplicationRecord
  self.table_name = "actor_profile_deltas"

  belongs_to :cluster

  validates :cluster_id, presence: true
  validates :block_height, presence: true

  scope :unprocessed, -> { where(processed_at: nil) }
  scope :after_height, ->(height) { where("block_height > ?", height.to_i) }
end