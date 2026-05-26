# app/services/actor_labels/mark_etf_like.rb
module ActorLabels
  class MarkEtfLike
    def self.call(cluster_id:, name:, confidence: 90, source: "manual", metadata: {})
      ActorLabel.find_or_initialize_by(
        cluster_id: cluster_id,
        label: "etf_like",
        source: source
      ).tap do |label|
        label.confidence = confidence
        label.metadata = {
          name: name,
          entity_type: "spot_bitcoin_etf"
        }.merge(metadata)
        label.save!
      end
    end
  end
end
