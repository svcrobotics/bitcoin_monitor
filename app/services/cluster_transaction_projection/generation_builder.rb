# frozen_string_literal: true

module ClusterTransactionProjection
  class GenerationBuilder
    def self.call(...)
      new(...).call
    end

    def initialize(
      cluster_id:,
      composition_version:,
      checkpoint_height:,
      checkpoint_hash:,
      source: "manual",
      facts: []
    )
      @cluster_id = cluster_id.to_i
      @composition_version = composition_version.to_i
      @checkpoint_height = checkpoint_height.to_i
      @checkpoint_hash = checkpoint_hash.to_s
      @source = source.to_s
      @facts = Array(facts)
    end

    def call
      generation = nil

      validate_fact_heights!

      ApplicationRecord.transaction do
        generation =
          ClusterTransactionProjectionGeneration.create!(
            cluster_id: cluster_id,
            composition_version: composition_version,
            base_checkpoint_height: checkpoint_height,
            base_checkpoint_hash: checkpoint_hash,
            checkpoint_height: checkpoint_height,
            checkpoint_hash: checkpoint_hash,
            source: source,
            status: "building",
            started_at: Time.current
          )

        insert_facts!(generation)
      end

      generation
    end

    private

    attr_reader(
      :cluster_id,
      :composition_version,
      :checkpoint_height,
      :checkpoint_hash,
      :source,
      :facts
    )

    def insert_facts!(generation)
      rows =
        facts.map do |fact|
          now = Time.current

          {
            projection_generation_id: generation.id,
            txid: Txid.pack(fact.fetch(:txid)),
            received_height: fact[:received_height],
            spent_height: fact[:spent_height],
            created_at: now,
            updated_at: now
          }
        end

      return if rows.empty?

      ClusterTransactionFact.insert_all!(rows)
    end

    def validate_fact_heights!
      facts.each do |fact|
        %i[received_height spent_height].each do |field|
          value = fact[field]
          next if value.nil?

          height = Integer(value)
          if height.negative? || height > checkpoint_height
            raise ArgumentError,
              "#{field} must belong to the certified checkpoint window"
          end
        rescue ArgumentError, TypeError
          raise ArgumentError,
            "#{field} must belong to the certified checkpoint window"
        end
      end
    end
  end
end
