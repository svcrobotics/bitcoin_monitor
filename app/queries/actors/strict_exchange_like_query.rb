# frozen_string_literal: true

module Actors
  class StrictExchangeLikeQuery
    LABEL = "exchange_like"

    def self.call(
      min_confidence: 0
    )
      new(
        min_confidence:
          min_confidence
      ).call
    end

    def initialize(
      min_confidence:
    )
      @min_confidence =
        [
          min_confidence.to_i,
          0
        ].max
    end

    def call
      ActorLabel
        .where(
          label: LABEL,
          source: strict_source
        )
        .where(
          "confidence >= ?",
          min_confidence
        )
        .where.not(
          cluster_id: nil
        )
    end

    private

    attr_reader :min_confidence

    def strict_source
      ActorLabels::StrictWriter::SOURCE
    end
  end
end
