# app/jobs/actor_profiles_compute_job.rb
# frozen_string_literal: true

class ActorProfilesComputeJob < ApplicationJob
  queue_as :p3_actor_profile_light

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(cluster_id)
    cluster_id = cluster_id.to_i
    return if cluster_id <= 0

    profile = ActorProfiles::ApplyDeltas.call(cluster_id: cluster_id)

    profile ||= rebuild_profile(cluster_id)

    refresh_actor_labels(profile)

    profile
  end

  private

  def rebuild_profile(cluster_id)
    rebuilt = ActorProfiles::BuildFromCluster.call(cluster_id: cluster_id)

    ActorProfileDelta
      .where(cluster_id: cluster_id, processed_at: nil)
      .update_all(processed_at: Time.current, updated_at: Time.current)

    rebuilt
  end

  def refresh_actor_labels(profile)
    return if profile.blank?

    ActorLabels::RefreshFromActorProfile.call(actor_profile: profile)
  rescue StandardError => e
    Rails.logger.warn(
      "[actor_profiles_compute] actor_label_refresh_failed " \
      "cluster_id=#{profile&.cluster_id} #{e.class}: #{e.message}"
    )
  end
end