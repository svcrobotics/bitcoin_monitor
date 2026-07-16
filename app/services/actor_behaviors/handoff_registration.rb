# frozen_string_literal: true

module ActorBehaviors
  class HandoffRegistration
    def self.call(actor_profile:, composition_version:, profile_version:,
      source_height:, source_hash:)
      new(actor_profile:, composition_version:, profile_version:,
        source_height:, source_hash:).call
    end

    def initialize(actor_profile:, composition_version:, profile_version:,
      source_height:, source_hash:)
      @actor_profile = actor_profile
      @cluster_id = positive_integer(actor_profile&.cluster_id, :cluster_id)
      @composition_version = positive_integer(composition_version, :composition_version)
      @profile_version = profile_version.to_s
      @source_height = nonnegative_integer(source_height, :source_height)
      @source_hash = source_hash.to_s
      raise ArgumentError, "profile_version must be present" if @profile_version.empty?
      raise ArgumentError, "source_hash must be present" if @source_hash.empty?
    end

    def call
      raise ArgumentError, "actor profile must be persisted" unless @actor_profile&.persisted?
      raise ArgumentError, "profile composition does not match" unless
        @actor_profile.cluster_composition_version.to_i == @composition_version
      raise ArgumentError, "profile source height does not match" unless
        @actor_profile.last_computed_height.to_i == @source_height
      raise ArgumentError, "profile source hash does not match" unless
        @actor_profile.metadata.to_h["address_spend_projection_hash"] == @source_hash
      raise ArgumentError, "actor profile is not strictly certified" unless
        @actor_profile.certification_scope == "strict" &&
          @actor_profile.certified_at.present? && !@actor_profile.dirty?

      handoff = ActorBehaviorBuildHandoff.find_or_initialize_by(identity)
      created = handoff.new_record?
      handoff.actor_profile = @actor_profile
      handoff.save! if created

      {
        ok: true,
        status: created ? "created" : "already_registered",
        handoff_id: handoff.id,
        cluster_id: @cluster_id,
        cluster_composition_version: @composition_version,
        profile_version: @profile_version,
        source_height: @source_height,
        source_hash: @source_hash
      }
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    def identity
      {
        cluster_id: @cluster_id,
        cluster_composition_version: @composition_version,
        profile_version: @profile_version,
        source_height: @source_height,
        source_hash: @source_hash
      }
    end

    def positive_integer(value, name)
      integer = value.is_a?(String) ? Integer(value, 10) : Integer(value)
      raise ArgumentError unless integer.positive?
      integer
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a positive integer"
    end

    def nonnegative_integer(value, name)
      integer = value.is_a?(String) ? Integer(value, 10) : Integer(value)
      raise ArgumentError if integer.negative?
      integer
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a nonnegative integer"
    end
  end
end
