# app/services/actor_labels/refresh_from_actor_profile.rb
# frozen_string_literal: true

module ActorLabels
  class RefreshFromActorProfile
    SOURCE = "actor_profile"
    ETF_CANDIDATE_THRESHOLD = 90

    def self.call(actor_profile:)
      new(actor_profile).call
    end

    def initialize(actor_profile)
      @profile = actor_profile
    end

    def call
      return [] if @profile.blank?

      labels = []

      primary = primary_label

      if primary.present? && primary != "unknown"
        ActorLabel
          .where(cluster_id: @profile.cluster_id, source: SOURCE)
          .where.not(label: [primary, "etf_candidate"])
          .delete_all

        labels << upsert_label(primary, confidence_for(primary))
      end

      if etf_candidate?
        labels << upsert_label("etf_candidate", @profile.etf_score.to_i)
      else
        ActorLabel
          .where(cluster_id: @profile.cluster_id, source: SOURCE, label: "etf_candidate")
          .delete_all
      end

      labels
    end

    private

    def primary_label
      @profile.classification.presence || "unknown"
    end

    def etf_candidate?
      @profile.etf_score.to_i >= ETF_CANDIDATE_THRESHOLD
    end

    def confidence_for(label)
      case label.to_s
      when "exchange_like"
        @profile.exchange_score
      when "whale_like"
        @profile.whale_score
      when "service_like"
        @profile.service_score
      when "etf_candidate"
        @profile.etf_score
      else
        0
      end
    end

    def upsert_label(label, score)
      ActorLabel.find_or_initialize_by(
        cluster_id: @profile.cluster_id,
        label: label,
        source: SOURCE
      ).tap do |actor_label|
        actor_label.actor_profile_id = @profile.id
        actor_label.confidence = score
        actor_label.metadata = metadata_for(label)
        actor_label.save!
      end
    end

    def metadata_for(label)
      {
        actor_profile_id: @profile.id,
        classification: @profile.classification,
        label: label,
        candidate: label.to_s == "etf_candidate",
        received_btc: @profile.total_received_btc,
        sent_btc: @profile.total_sent_btc,
        balance_btc: @profile.balance_btc,
        net_btc: @profile.net_btc,
        tx_count: @profile.tx_count,
        scores: {
          whale: @profile.whale_score,
          exchange: @profile.exchange_score,
          service: @profile.service_score,
          etf: @profile.etf_score
        }
      }
    end
  end
end