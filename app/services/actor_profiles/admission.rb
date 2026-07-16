# frozen_string_literal: true

module ActorProfiles
  class Admission
    def self.register(cluster_id:, composition_version:, source_height:, source_hash:, reason:)
      new(cluster_id:, composition_version:, source_height:, source_hash:, reason:).register
    end

    def initialize(cluster_id:, composition_version:, source_height:, source_hash:, reason:)
      @cluster_id = positive_integer(cluster_id, :cluster_id)
      @composition_version = positive_integer(composition_version, :composition_version)
      @source_height = nonnegative_integer(source_height, :source_height)
      @source_hash = source_hash.to_s
      @reason = reason.to_s
      raise ArgumentError, "source_hash must be present" if @source_hash.empty?
      raise ArgumentError, "invalid reason" unless ActorProfileBuildAdmission::REASONS.include?(@reason)
    end

    def register
      validate_provenance!
      admission = nil
      created = false

      ActorProfileBuildAdmission.transaction(requires_new: false) do
        admission = ActorProfileBuildAdmission.find_or_initialize_by(identity)
        if admission.new_record?
          admission.reason = @reason
          admission.save!
          created = true
        end
      end

      {
        ok: true,
        status: created ? "created" : "already_registered",
        admission_id: admission.id,
        cluster_id: @cluster_id,
        cluster_composition_version: @composition_version,
        source_height: @source_height,
        source_hash: @source_hash,
        reason: admission.reason
      }
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    def identity
      {
        cluster_id: @cluster_id,
        cluster_composition_version: @composition_version,
        source_height: @source_height,
        source_hash: @source_hash
      }
    end

    def validate_provenance!
      cluster = Cluster.find_by(id: @cluster_id)
      raise ArgumentError, "cluster is unavailable" unless cluster
      raise ArgumentError, "cluster composition version is not current" unless
        cluster.composition_version.to_i == @composition_version

      cluster_checkpoint = ClusterProcessedBlock.find_by(
        height: @source_height, status: "processed", block_hash: @source_hash
      )
      projection_checkpoint = AddressSpendProjectionBlock.find_by(
        height: @source_height, status: "completed", block_hash: @source_hash
      )
      raise ArgumentError, "certified source checkpoint is unavailable" unless
        cluster_checkpoint && projection_checkpoint
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
