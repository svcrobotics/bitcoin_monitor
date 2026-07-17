# frozen_string_literal: true

class TansaHeartbeatController < ApplicationController
  def show
    response.headers["Cache-Control"] = "no-store"

    layer1 = Layer1::Realtime::CachedHealthSnapshot.read

    layer1_processed =
      layer1.dig(:sync, :processed_height) ||
      layer1[:processed_height]

    layer1_lag =
      layer1.dig(:sync, :lag) ||
      layer1[:lag] ||
      0

    buffers = layer1[:buffers] || {}

    processing_height =
      layer1.dig(:strict, :processing_block, :height) ||
      layer1.dig(:strict, :processing_block, "height")

    network_cadence =
      Layer1::Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: layer1[:bitcoin_core_height],
        processed_height: layer1_processed,
        processing_height: processing_height
      )

    cluster_tip =
      if defined?(ClusterProcessedBlock)
        ClusterProcessedBlock.where(status: "processed").maximum(:height)
      end

    cluster_lag =
      if layer1_processed.present? && cluster_tip.present?
        [layer1_processed.to_i - cluster_tip.to_i, 0].max
      else
        0
      end

    actor_snapshot =
      if defined?(ActorProfiles::StrictHealthSnapshot)
        ActorProfiles::StrictHealthSnapshot.call
      else
        {}
      end

    actor_profile_height =
      actor_snapshot.dig(:sync, :profile_max_height) ||
      actor_snapshot.dig(:sync, :profile_height) ||
      actor_snapshot.dig(:sync, :actor_profile_height)

    actor_height_lag =
      if cluster_tip.present? && actor_profile_height.present?
        [cluster_tip.to_i - actor_profile_height.to_i, 0].max
      else
        0
      end

    actor_missing = actor_snapshot.dig(:progress, :missing_profiles).to_i
    actor_stale = actor_snapshot.dig(:progress, :stale_profiles).to_i
    actor_profiles = actor_snapshot.dig(:progress, :actor_profiles).to_i
    actor_completion = actor_snapshot.dig(:progress, :completion_pct)

    status =
      if layer1_lag.to_i > 6 || cluster_lag.to_i > 6
        "critical"
      elsif layer1_lag.to_i.positive? || cluster_lag.to_i.positive? || actor_missing.positive?
        "syncing"
      else
        "healthy"
      end

    render json: {
      status: status,

      height: layer1_processed.to_i,

      layer1_lag: layer1_lag.to_i,
      cluster_lag: cluster_lag.to_i,

      actor_profile_lag: actor_height_lag.to_i,
      actor_profile_missing: actor_missing.to_i,
      actor_profile_missing_label: compact_number(actor_missing),

      layer1: {
        processed_height: layer1_processed.to_i,
        lag: layer1_lag.to_i
      },

      cluster: {
        tip: cluster_tip.to_i,
        lag_vs_layer1: cluster_lag.to_i
      },

      actor_profile: {
        cluster_tip: cluster_tip.to_i,
        profile_height: actor_profile_height.to_i,
        height_lag_vs_cluster: actor_height_lag.to_i,
        actor_profiles: actor_profiles,
        missing_profiles: actor_missing,
        stale_profiles: actor_stale,
        completion_pct: actor_completion,
        missing_label: compact_number(actor_missing)
      },

      buffers: {
        outputs: buffers[:outputs].to_i,
        spent: buffers[:spent].to_i
      },

      network_cadence: network_cadence,

      updated_at: Time.current.iso8601
    }
  rescue StandardError => e
    render json: {
      status: "unknown",
      error: e.class.name,
      message: e.message,
      updated_at: Time.current.iso8601
    }, status: :ok
  end

  private

  def compact_number(value)
    value = value.to_i

    if value >= 1_000_000
      "#{format('%.1f', value / 1_000_000.0).sub('.0', '')}M"
    elsif value >= 1_000
      "#{format('%.1f', value / 1_000.0).sub('.0', '')}k"
    else
      value.to_s
    end
  end
end
