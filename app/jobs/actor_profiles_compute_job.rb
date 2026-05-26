# app/jobs/actor_profiles_compute_job.rb
# frozen_string_literal: true

class ActorProfilesComputeJob < ApplicationJob
  queue_as :p3_actor_profile_light

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(cluster_id)
    cluster_id = cluster_id.to_i
    return if cluster_id <= 0

    profile = ActorProfiles::ApplyDeltas.call(cluster_id: cluster_id)

    profile ||= begin
      rebuilt = ActorProfiles::BuildFromCluster.call(cluster_id: cluster_id)

      ActorProfileDelta
        .where(cluster_id: cluster_id, processed_at: nil)
        .update_all(processed_at: Time.current, updated_at: Time.current)

      ActorLabels::RefreshFromActorProfile.call(actor_profile: rebuilt)

      rebuilt
    end

    profile
  end
end