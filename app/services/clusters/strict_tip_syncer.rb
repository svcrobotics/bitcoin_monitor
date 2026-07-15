# frozen_string_literal: true

module Clusters
  class StrictTipSyncer
    DEFAULT_LIMIT = 2
    MAX_LIMIT = 100
    CONTINUITY_DEPTH = 32

    class Error < StandardError; end
    class InvalidStartHeight < Error; end
    class ContinuityError < Error; end
    class Layer1Unavailable < Error; end
    class HashMismatch < Error; end
    class GuardDenied < Error; end

    def self.call(limit: DEFAULT_LIMIT, start_height: nil)
      new(limit: limit, start_height: start_height).call
    end

    def self.work_available?
      layer1_tip = BlockBufferModel.where(status: "processed").maximum(:height)
      return false unless layer1_tip

      cluster_tip = ClusterProcessedBlock.where(status: "processed").maximum(:height)
      cluster_tip.nil? || cluster_tip < layer1_tip
    end

    def initialize(limit:, start_height:, logger: Rails.logger)
      @limit = [[Integer(limit), 1].max, MAX_LIMIT].min
      @start_height = start_height.nil? ? nil : Integer(start_height)
      @logger = logger
    end

    def call
      cluster_tip = cluster_tip()
      layer1_tip = layer1_tip()
      raise Layer1Unavailable, "Layer1 processed checkpoint is unavailable" unless layer1_tip

      verify_bounded_continuity!(cluster_tip)
      next_height = next_height(cluster_tip)
      return idle_result(cluster_tip, layer1_tip) if next_height > layer1_tip

      results = []
      while results.size < @limit && next_height <= layer1_tip
        decision = guard_decision!
        unless decision[:allowed]
          return result_payload(
            status: "preempted",
            before_tip: cluster_tip,
            layer1_tip: layer1_tip,
            results: results,
            next_height: next_height,
            decision: decision
          )
        end

        validate_layer1_height!(next_height)
        rebuild = Clusters::StrictWindowRebuilder.call(
          from_height: next_height,
          to_height: next_height
        )
        unless rebuild[:ok] && rebuild[:status] == "processed"
          raise Error, "Cluster certification did not complete at height #{next_height}"
        end

        results << rebuild
        next_height += 1
      end

      wake_actor_profile_dispatcher if results.any?
      result_payload(
        status: "synced",
        before_tip: cluster_tip,
        layer1_tip: layer1_tip,
        results: results,
        next_height: next_height <= layer1_tip ? next_height : nil
      )
    end

    private

    def cluster_tip
      ClusterProcessedBlock.where(status: "processed").maximum(:height)
    end

    def layer1_tip
      BlockBufferModel.where(status: "processed").maximum(:height)
    end

    def next_height(cluster_tip)
      return cluster_tip + 1 if cluster_tip

      value = @start_height || ENV["CLUSTER_STRICT_START_HEIGHT"]
      raise InvalidStartHeight, "CLUSTER_STRICT_START_HEIGHT is required" if value.nil?

      height = Integer(value)
      raise InvalidStartHeight, "Cluster start height must be nonnegative" if height.negative?

      height
    rescue ArgumentError, TypeError
      raise InvalidStartHeight, "Cluster start height must be an integer"
    end

    def verify_bounded_continuity!(tip)
      return unless tip

      minimum = ClusterProcessedBlock.where(status: "processed").minimum(:height)
      from_height = [tip - CONTINUITY_DEPTH + 1, minimum].max
      rows = ClusterProcessedBlock
        .where(status: "processed", height: from_height..tip)
        .order(:height)
        .pluck(:height, :block_hash)
      expected = (from_height..tip).to_a
      unless rows.map(&:first) == expected
        raise ContinuityError, "Cluster checkpoint continuity is broken in the bounded window"
      end

      layer1_hashes = BlockBufferModel
        .where(status: "processed", height: from_height..tip)
        .pluck(:height, :block_hash)
        .to_h
      rows.each do |height, block_hash|
        raise HashMismatch, "Cluster checkpoint hash differs from Layer1 at height #{height}" unless
          layer1_hashes[height] == block_hash
      end
    end

    def validate_layer1_height!(height)
      block_hash, status = BlockBufferModel.where(height: height).pick(:block_hash, :status)
      unless status == "processed" && block_hash.present?
        raise Layer1Unavailable, "Layer1 height #{height} is not processed"
      end

      checkpoint = ClusterProcessedBlock.find_by(height: height)
      if checkpoint&.status == "processed" && checkpoint.block_hash != block_hash
        raise HashMismatch, "Cluster checkpoint hash differs at height #{height}"
      end
    end

    def guard_decision!
      decision = System::PipelineController.decision(:cluster)
      unless decision.is_a?(Hash) && [true, false].include?(decision[:allowed])
        raise GuardDenied, "Cluster PipelineController returned an invalid decision"
      end
      decision
    rescue GuardDenied
      raise
    rescue StandardError => error
      raise GuardDenied, "Cluster PipelineController failed with #{error.class.name}"
    end

    def wake_actor_profile_dispatcher
      return unless Clusters::ActorProfileHandoffDispatcher.work_available?

      Clusters::ActorProfileHandoffDispatchJob.perform_later
    rescue StandardError => error
      @logger.warn(
        "[cluster_strict_tip_syncer] actor_profile_wakeup_failed " \
        "error_class=#{error.class.name}"
      )
    end

    def idle_result(cluster_tip, layer1_tip)
      {
        ok: true,
        status: "idle",
        cluster_tip_before: cluster_tip,
        cluster_tip_after: cluster_tip,
        layer1_tip: layer1_tip,
        processed: 0,
        next_height: nil,
        results: []
      }
    end

    def result_payload(status:, before_tip:, layer1_tip:, results:, next_height:, decision: nil)
      {
        ok: true,
        status: status,
        cluster_tip_before: before_tip,
        cluster_tip_after: results.last&.dig(:height) || before_tip,
        layer1_tip: layer1_tip,
        processed: results.size,
        limit: @limit,
        next_height: next_height,
        decision: decision,
        results: results
      }
    end
  end
end
