# app/models/actor_profile.rb
class ActorProfile < ApplicationRecord
  belongs_to :cluster

  validates :cluster_id, presence: true, uniqueness: true
end