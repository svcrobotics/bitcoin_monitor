# app/services/actor_labels/refresh_from_actor_profile.rb
module ActorLabels
  class RefreshFromActorProfile
    def self.call(actor_profile:)
      new(actor_profile).call
    end

    def initialize(actor_profile)
      @profile = actor_profile
    end

    def call
      labels = []

      labels << upsert_label("exchange_like", @profile.exchange_score) if exchange_like?
      labels << upsert_label("whale_like", @profile.whale_score) if whale_like?
      labels << upsert_label("service_like", @profile.service_score) if service_like?
      labels << upsert_label("etf_like", @profile.etf_score) if etf_like?

      labels.compact
    end

    private

    def exchange_like?
      @profile.exchange_score.to_i >= 70
    end

    def whale_like?
      @profile.whale_score.to_i >= 70 &&
        @profile.total_received_btc.to_d >= 1_000 &&
        @profile.net_btc.to_d >= 100
    end

    def service_like?
      @profile.service_score.to_i >= 70
    end

    def etf_like?
      @profile.etf_score.to_i >= 85 &&
        @profile.total_received_btc.to_d >= 10_000 &&
        @profile.net_btc.to_d >= 5_000 &&
        @profile.tx_count.to_i <= 500
    end

    def upsert_label(label, score)
      ActorLabel.find_or_initialize_by(
        cluster_id: @profile.cluster_id,
        label: label,
        source: "actor_profile"
      ).tap do |actor_label|
        actor_label.actor_profile_id = @profile.id
        actor_label.confidence = score
        actor_label.metadata = {
          actor_profile_id: @profile.id,
          classification: @profile.classification,
          received_btc: @profile.total_received_btc,
          sent_btc: @profile.total_sent_btc,
          net_btc: @profile.net_btc,
          tx_count: @profile.tx_count,
          scores: {
            whale: @profile.whale_score,
            exchange: @profile.exchange_score,
            service: @profile.service_score,
            etf: @profile.etf_score
          }
        }
        actor_label.save!
      end
    end
  end
end