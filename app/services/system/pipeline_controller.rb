# frozen_string_literal: true

module System
  class PipelineController
    LAYER1_STRICT_QUEUE = "layer1_strict"
    CLUSTER_STRICT_QUEUE = "cluster_strict"
    ADDRESS_SPEND_PROJECTION_QUEUE =
      "actor_profile_strict"
    ACTOR_PROFILE_STRICT_QUEUE = "actor_profile_strict"
    ACTOR_BEHAVIOR_STRICT_QUEUE = "actor_behavior_strict"
    ACTOR_BEHAVIOR_HEAVY_QUEUE = "actor_behavior_heavy"
    ACTOR_LABELS_STRICT_QUEUE = "actor_labels_strict"

    PIPELINE_MODE_ENV = "TANSA_PIPELINE_MODE"
    DEVELOPMENT_BACKFILL_MODE = "development_backfill"

    DEVELOPMENT_BACKFILL_DOWNSTREAM_MODULES = %i[
      cluster
      address_spend_projection
      actor_profile
      actor_behavior
      actor_behavior_heavy
      actor_labels
      layer1_audit
      tx_outputs_async
      tx_output_projection
      coverage
    ].freeze

    BACKFILL_MAX_LAYER1_LAG_ENV =
      "TANSA_BACKFILL_MAX_LAYER1_LAG"

    BACKFILL_MAX_CLUSTER_GLOBAL_LAG_ENV =
      "TANSA_BACKFILL_MAX_CLUSTER_GLOBAL_LAG"

    ACTOR_PROFILE_MAX_LAYER1_LAG = 3
    ACTOR_PROFILE_MAX_CLUSTER_GLOBAL_LAG = 3
    ACTOR_PROFILE_MAX_CLUSTER_LAG = 3

    CLUSTER_MAX_LAYER1_LAG = 3

    ROLE_ALIASES = {
      layer1: :layer1_realtime
    }.freeze

    LAYER1_STABLE_CONSTRAINTS = [
      :layer1_checkpoint_available,
      :layer1_not_processing,
      :layer1_buffers_empty,
      :layer1_strict_queue_idle,
      :layer1_strict_worker_idle,
      :layer1_not_catching_up
    ].freeze

    CLUSTER_UPSTREAM_CONSTRAINTS = [
      :layer1_checkpoint_available,
      :cluster_layer1_lag_within_budget,
      :layer1_not_processing,
      :layer1_buffers_empty,
      :layer1_strict_queue_idle,
      :layer1_strict_worker_idle,
      :strict_io_not_layer1
    ].freeze

    CLUSTER_STABLE_CONSTRAINTS = [
      :cluster_checkpoint_available,
      :cluster_not_processing,
      :cluster_strict_queue_idle,
      :cluster_strict_worker_idle,
      :cluster_caught_up_to_layer1
    ].freeze

    ACTOR_PROFILE_STABLE_CONSTRAINTS = [
      :actor_profile_checkpoint_available,
      :actor_profile_not_processing,
      :actor_profile_strict_queue_idle,
      :actor_profile_strict_worker_idle,
      :actor_profile_no_pending_work
    ].freeze

    ACTOR_LABELS_STABLE_CONSTRAINTS = [
      :actor_labels_strict_queue_idle,
      :actor_labels_strict_worker_idle
    ].freeze

    STRICT_UPSTREAM_CONSTRAINTS = [
      *LAYER1_STABLE_CONSTRAINTS,
      *CLUSTER_STABLE_CONSTRAINTS
    ].freeze

    ADDRESS_SPEND_UPSTREAM_CONSTRAINTS = [
      :bitcoin_core_available,
      :layer1_checkpoint_available,
      :actor_profile_layer1_lag_within_budget,
      :cluster_checkpoint_available,
      :actor_profile_cluster_global_lag_within_budget,
      :address_spend_projection_available
    ].freeze

    ACTOR_PROFILE_UPSTREAM_CONSTRAINTS = [
      :bitcoin_core_available,
      :layer1_checkpoint_available,
      :actor_profile_layer1_lag_within_budget,
      :cluster_checkpoint_available,
      :actor_profile_cluster_global_lag_within_budget,
      :address_spend_projection_ready
    ].freeze

    # En mode development_backfill, Cluster peut rattraper le
    # checkpoint Layer1 disponible même si Layer1 reste légèrement
    # derrière Bitcoin Core.
    DEVELOPMENT_BACKFILL_CLUSTER_CONSTRAINTS = [
      :layer1_checkpoint_available,
      :layer1_not_processing,
      :layer1_buffers_empty,
      :layer1_strict_queue_idle,
      :layer1_strict_worker_idle,
      :strict_io_not_layer1
    ].freeze

    # ActorProfile travaille depuis le dernier checkpoint Cluster
    # certifié. En mode development_backfill, un retard relatif maximal
    # de trois blocs entre Cluster et Layer1 est accepté afin que les
    # étapes aval puissent continuer leur rattrapage.
    DEVELOPMENT_BACKFILL_ADDRESS_SPEND_CONSTRAINTS = [
      :layer1_checkpoint_available,
      :cluster_checkpoint_available,
      :actor_profile_cluster_lag_within_budget,
      :development_backfill_upstream_within_guardrails,
      :address_spend_projection_available
    ].freeze

    DEVELOPMENT_BACKFILL_ACTOR_PROFILE_CONSTRAINTS = [
      :layer1_checkpoint_available,
      :cluster_checkpoint_available,
      :actor_profile_cluster_lag_within_budget,
      :development_backfill_upstream_within_guardrails,
      :address_spend_projection_ready
    ].freeze

    LAYER1_HEAVY_CONSTRAINTS = [
      :strict_io_idle,
      *LAYER1_STABLE_CONSTRAINTS,
      *CLUSTER_STABLE_CONSTRAINTS,
      *ACTOR_PROFILE_STABLE_CONSTRAINTS,
      *ACTOR_LABELS_STABLE_CONSTRAINTS
    ].freeze

    # La projection historique doit céder devant le temps réel,
    # mais ne doit pas attendre que tous les backlogs applicatifs
    # ActorProfile / ActorBehavior / ActorLabels soient terminés.
    #
    # Un retard faible de Bitcoin Core est normal. Le travail
    # historique peut donc avancer dans les fenêtres où Layer1 et
    # Cluster ne traitent pas activement un bloc.
    HISTORICAL_PROJECTION_CONSTRAINTS = [
      :strict_io_idle,
      :layer1_checkpoint_available,
      :historical_layer1_lag_within_budget,

      :cluster_checkpoint_available,
      :historical_cluster_lag_within_budget
    ].freeze

    COVERAGE_CONSTRAINTS = [
      :strict_io_idle,
      *LAYER1_STABLE_CONSTRAINTS,
      *CLUSTER_STABLE_CONSTRAINTS,
      *ACTOR_PROFILE_STABLE_CONSTRAINTS,
      *ACTOR_LABELS_STABLE_CONSTRAINTS
    ].freeze

    PIPELINE_REGISTRY = {
      bitcoin_core: {
        priority: 0,
        depends_on: [],
        constraints: [],
        realtime: true,
        role: :external_source
      },

      layer1_realtime: {
        priority: 1,
        depends_on: [:bitcoin_core],
        constraints: [:bitcoin_core_available],
        realtime: true,
        role: :source_of_truth
      },

      cluster: {
        priority: 2,
        depends_on: [:layer1_realtime],
        constraints: CLUSTER_UPSTREAM_CONSTRAINTS,
        realtime: true,
        role: :identity_layer
      },

      address_spend_projection: {
        priority: 3,
        depends_on: [:cluster],
        constraints: ADDRESS_SPEND_UPSTREAM_CONSTRAINTS,
        realtime: false,
        role: :strict_projection
      },

      actor_profile: {
        priority: 4,
        depends_on: [:address_spend_projection],
        constraints: ACTOR_PROFILE_UPSTREAM_CONSTRAINTS,
        realtime: false,
        role: :profile_builder
      },

      actor_labels: {
        priority: 6,
        depends_on: [:actor_behavior],
        constraints: [],
        realtime: false,
        role: :label_builder
      },

      actor_behavior: {
        priority: 5,
        depends_on: [:actor_profile],
        constraints: [],
        realtime: false,
        role: :behavior_builder
      },

      actor_behavior_heavy: {
        priority: 6,
        depends_on: [:actor_behavior],
        constraints: [],
        realtime: false,
        role: :behavioral_resolution
      },

      layer1_audit: {
        priority: 5,
        depends_on: [:layer1_realtime, :cluster],
        constraints: LAYER1_HEAVY_CONSTRAINTS,
        realtime: false,
        role: :layer1_heavy
      },

      tx_outputs_async: {
        priority: 5,
        depends_on: [:layer1_realtime, :cluster],
        constraints: HISTORICAL_PROJECTION_CONSTRAINTS,
        realtime: false,
        role: :historical_projection
      },

      tx_output_projection: {
        priority: 5,
        depends_on: [:layer1_realtime, :cluster],
        constraints: HISTORICAL_PROJECTION_CONSTRAINTS,
        realtime: false,
        role: :historical_projection
      },

      coverage: {
        priority: 7,
        depends_on: [:cluster],
        constraints: COVERAGE_CONSTRAINTS,
        realtime: false,
        role: :maintenance
      }
    }.freeze

    def self.snapshot
      redis =
        Redis.new(
          url: ENV.fetch(
            "REDIS_URL",
            "redis://127.0.0.1:6379/0"
          )
        )

      buffers = {
        outputs:
          redis
            .llen(Blockchain::Buffers::OutputBuffer::KEY)
            .to_i,

        spent:
          redis
            .llen(Blockchain::Buffers::SpentOutputBuffer::KEY)
            .to_i
      }

      bitcoin_core_available = true
      bitcoin_core_error = nil

      best =
        begin
          BitcoinRpc
            .new
            .getblockcount
            .to_i
        rescue StandardError => error
          bitcoin_core_available = false
          bitcoin_core_error = "#{error.class}: #{error.message}"
          0
        end

      processed =
        BlockBufferModel
          .where(status: "processed")
          .maximum(:height)
          .to_i

      processing_height =
        BlockBufferModel
          .where(status: "processing")
          .minimum(:height)

      lag =
        [
          best - processed,
          0
        ].max

      development_backfill =
        System::DevelopmentBackfillPhase.resolve(
          layer1_lag:
            bitcoin_core_available ?
              lag :
              nil,
          redis: redis
        )

      buffers_empty =
        buffers
          .values
          .none?(&:positive?)

      strict_io_owner =
        StrictPipeline::StrictIoLease.current

      processing =
        processing_height.present?

      layer1_strict_queue_size =
        sidekiq_queue_size(LAYER1_STRICT_QUEUE)

      layer1_strict_worker_busy =
        sidekiq_worker_busy?(LAYER1_STRICT_QUEUE)

      cluster_processed =
        ClusterProcessedBlock
          .where(status: "processed")
          .maximum(:height)
          .to_i

      cluster_processing_height =
        ClusterProcessedBlock
          .where(status: "processing")
          .minimum(:height)

      cluster_lag =
        [
          processed - cluster_processed,
          0
        ].max

      cluster_global_lag =
        [
          best - cluster_processed,
          0
        ].max

      cluster_strict_queue_size =
        sidekiq_queue_size(CLUSTER_STRICT_QUEUE)

      cluster_strict_worker_busy =
        sidekiq_worker_busy?(CLUSTER_STRICT_QUEUE) ||
        sidekiq_work_active?(
          queue_name: CLUSTER_STRICT_QUEUE,
          job_class: "Clusters::StrictTipSyncJob"
        )

      cluster_processing =
        cluster_processing_height.present? ||
        cluster_strict_worker_busy

      cluster_processing_height ||=
        if cluster_strict_worker_busy && cluster_lag.positive?
          cluster_processed + 1
        end

      address_spend_projection =
        address_spend_projection_snapshot(
          cluster_processed:
            cluster_processed
        )

      actor_profile =
        actor_profile_snapshot(
          cluster_processed: cluster_processed
        )

      actor_labels =
        actor_labels_snapshot

      {
        development_backfill:
          development_backfill,

        bitcoin_core: {
          available: bitcoin_core_available,
          best_height: best,
          error: bitcoin_core_error
        },

        layer1: {
          processed_height: processed,
          lag: lag,

          processing: processing,
          processing_height: processing_height,

          buffers: buffers,
          buffers_empty: buffers_empty,

          idle:
            !processing &&
            buffers_empty &&
            layer1_strict_queue_size.to_i.zero? &&
            !layer1_strict_worker_busy,

          strict_queue_size:
            layer1_strict_queue_size,

          strict_worker_busy:
            layer1_strict_worker_busy,

          strict_active:
            processing ||
            layer1_strict_queue_size.to_i.positive? ||
            layer1_strict_worker_busy,

          checkpoint_available:
            processed.positive?,

          catching_up:
            layer1_catching_up?(
              lag: lag,
              processing: processing,
              buffers_empty: buffers_empty,
              strict_queue_size: layer1_strict_queue_size,
              strict_worker_busy: layer1_strict_worker_busy
            )
        },

        cluster: {
          processed_height: cluster_processed,
          lag: cluster_lag,
          global_lag: cluster_global_lag,

          processing: cluster_processing,
          processing_height: cluster_processing_height,

          idle:
            !cluster_processing &&
            cluster_strict_queue_size.to_i.zero? &&
            !cluster_strict_worker_busy,

          strict_queue_size:
            cluster_strict_queue_size,

          strict_worker_busy:
            cluster_strict_worker_busy,

          checkpoint_available:
            cluster_processed.positive?,

          caught_up_to_layer1:
            cluster_lag.zero?
        },

        address_spend_projection:
          address_spend_projection,

        actor_profile: actor_profile,
        actor_labels: actor_labels,

        strict_io: {
          owner: strict_io_owner&.owner,
          acquired_at: strict_io_owner&.acquired_at&.iso8601(6),
          expires_at: strict_io_owner&.expires_at&.iso8601(6)
        }
      }
    rescue => e
      {
        error: "#{e.class}: #{e.message}"
      }
    end

    def self.allow?(module_name)
      decision(module_name)[:allowed]
    end

    def self.status(module_name)
      decision(module_name)
    end

    def self.bitcoin_core_status
      status(:bitcoin_core)
    end

    def self.layer1_status
      decision(:layer1_realtime)
    end

    def self.decision(module_name, current_snapshot: nil)
      name =
        canonical_module_name(module_name)

      config =
        PIPELINE_REGISTRY[name]

      return unknown_module_decision(name) unless config

      current_snapshot ||=
        snapshot

      phase_decision =
        development_backfill_phase_decision(
          name,
          config,
          current_snapshot
        )

      return phase_decision if phase_decision

      if name == :actor_behavior
        downstream_decision =
          actor_behavior_decision(
            current_snapshot: current_snapshot
          )

        return development_backfill_downstream_decision(
          downstream_decision,
          current_snapshot: current_snapshot
        )
      end

      if name == :actor_behavior_heavy
        return actor_behavior_heavy_decision(
          current_snapshot:
            current_snapshot
        )
      end

      if name == :actor_labels
        downstream_decision =
          actor_labels_decision(
            current_snapshot: current_snapshot
          )

        return development_backfill_downstream_decision(
          downstream_decision,
          current_snapshot: current_snapshot
        )
      end

      constraints =
        constraints_for(
          name,
          config
        )

      failed =
        failed_constraints(
          constraints,
          current_snapshot
        )

      allowed =
        failed.empty?

      {
        module: name,
        allowed: allowed,
        state: state_for(name, allowed, current_snapshot),
        reason: reason_for_module(name, failed, current_snapshot),
        retry_in: retry_in_for(name, failed),
        priority: config[:priority],
        depends_on: config[:depends_on],
        constraints: constraints,
        failed_constraints: failed,
        realtime: config[:realtime],
        role: config[:role],
        architecture_role: config[:role],
        resources: resources(name),
        snapshot: current_snapshot
      }
    end

    def self.next_runnable_modules
      PIPELINE_REGISTRY
        .keys
        .map { |name| decision(name) }
        .select { |decision| decision[:allowed] }
        .sort_by { |decision| [decision[:priority].to_i, decision[:module].to_s] }
    end

    def self.next_module
      next_runnable_modules
        .reject { |decision| decision[:module] == :bitcoin_core }
        .select { |decision| work_available?(decision) }
        .first
    end

    def self.work_available?(decision)
      snapshot =
        decision[:snapshot]

      case decision[:module]
      when :bitcoin_core
        false

      when :layer1_realtime
        layer1_realtime_work_available?(snapshot)

      when :cluster
        cluster_work_available?(snapshot)

      when :address_spend_projection
        address_spend_projection_work_available?(
          snapshot
        )

      when :actor_profile
        actor_profile_work_available?(snapshot)

      when :actor_labels
        actor_labels_work_available?(decision)

      when :actor_behavior
        actor_behavior_work_available?(decision)

      when :actor_behavior_heavy
        actor_behavior_heavy_work_available?(
          decision
        )

      when :layer1_audit
        scheduler_only_work_available?(:layer1_audit)

      when :tx_outputs_async
        tx_outputs_async_work_available?

      when :tx_output_projection
        tx_output_projection_work_available?

      when :coverage
        coverage_work_available?

      else
        raise ArgumentError, "Unhandled pipeline role #{decision[:module].inspect}"
      end
    end

    def self.layer1_realtime_work_available?(snapshot)
      normal_work =
        snapshot.dig(:layer1, :processing) == true ||
        snapshot.dig(:layer1, :lag).to_i.positive? ||
        snapshot.dig(:layer1, :buffers, :outputs).to_i.positive? ||
        snapshot.dig(:layer1, :buffers, :spent).to_i.positive? ||
        snapshot.dig(:layer1, :strict_queue_size).to_i.positive? ||
        snapshot.dig(:layer1, :strict_worker_busy) == true

      if development_backfill_alternating_enabled?(
        snapshot
      )
        return (
          snapshot.dig(
            :development_backfill,
            :phase
          ).to_s == "layer1_catchup" &&
            normal_work
        )
      end

      return normal_work unless development_backfill_mode?

      snapshot.dig(:layer1, :processing) == true ||
        snapshot.dig(:layer1, :buffers, :outputs).to_i.positive? ||
        snapshot.dig(:layer1, :buffers, :spent).to_i.positive? ||
        snapshot.dig(:layer1, :lag).to_i >
          development_backfill_max_layer1_lag ||
        snapshot.dig(:layer1, :strict_queue_size).to_i.positive? ||
        snapshot.dig(:layer1, :strict_worker_busy) == true
    end

    def self.cluster_work_available?(snapshot)
      normal_work =
        snapshot.dig(:cluster, :lag).to_i.positive? ||
        snapshot.dig(:cluster, :processing) == true

      return normal_work unless development_backfill_mode?

      # Cluster doit rattraper le checkpoint Layer1 disponible.
      # Le retard de Layer1 par rapport à Bitcoin Core n'empêche pas
      # ce rattrapage tant que Layer1 est au repos et cohérent.
      snapshot.dig(:cluster, :lag).to_i.positive? ||
        snapshot.dig(:cluster, :processing) == true ||
        snapshot.dig(:cluster, :strict_queue_size).to_i.positive? ||
        snapshot.dig(:cluster, :strict_worker_busy) == true
    end

    def self.address_spend_projection_work_available?(
      snapshot
    )
      projection =
        snapshot[
          :address_spend_projection
        ] || {}

      projection[:work_available] == true ||
        projection[:processing] == true
    end

    def self.actor_profile_work_available?(snapshot)
      snapshot.dig(:actor_profile, :pending_work).to_i.positive? ||
        snapshot.dig(:actor_profile, :processing) == true
    end

    def self.actor_labels_work_available?(decision)
      decision.dig(:actor_labels, :work_available) == true &&
        decision[:state] == :run
    end

    def self.actor_behavior_work_available?(decision)
      decision.dig(:actor_behavior, :work_available) == true &&
        decision[:state] == :run
    end

    def self.actor_behavior_heavy_work_available?(
      decision
    )
      decision.dig(
        :actor_behavior_heavy,
        :work_available
      ) == true &&
        decision[:state] == :run
    end

    def self.actor_behavior_heavy_decision(
      current_snapshot:
    )
      current_snapshot ||=
        snapshot

      control =
        ActorBehaviors::Heavy::
          ControlSnapshot.call(
            current_snapshot:
              current_snapshot
          )

      strict_behavior =
        actor_behavior_decision(
          current_snapshot:
            current_snapshot
        )

      strict_behavior_control =
        strict_behavior[
          :actor_behavior
        ] || {}

      actor_labels =
        current_snapshot[
          :actor_labels
        ] || {}

      failed = []

      unless current_snapshot.dig(
        :bitcoin_core,
        :available
      ) == true
        failed <<
          :bitcoin_core_available
      end

      if current_snapshot.dig(
        :strict_io,
        :owner
      ).present?
        failed <<
          :strict_io_idle
      end

      unless current_snapshot.dig(
        :layer1,
        :checkpoint_available
      ) == true
        failed <<
          :layer1_checkpoint_available
      end

      unless current_snapshot.dig(
        :layer1,
        :idle
      ) == true
        failed <<
          :layer1_stable
      end

      if current_snapshot.dig(
        :layer1,
        :catching_up
      ) == true
        failed <<
          :layer1_not_catching_up
      end

      unless current_snapshot.dig(
        :cluster,
        :checkpoint_available
      ) == true
        failed <<
          :cluster_checkpoint_available
      end

      unless current_snapshot.dig(
        :cluster,
        :idle
      ) == true &&
             current_snapshot.dig(
               :cluster,
               :caught_up_to_layer1
             ) == true
        failed <<
          :cluster_stable
      end

      actor_profile =
        current_snapshot[
          :actor_profile
        ] || {}

      unless
        actor_profile[
          :checkpoint_available
        ] == true &&
        actor_profile[
          :processing
        ] != true &&
        actor_profile[
          :strict_queue_size
        ].to_i.zero? &&
        actor_profile[
          :strict_worker_busy
        ] != true &&
        actor_profile[
          :pending_work
        ].to_i.zero? &&
        actor_profile[
          :caught_up_to_cluster
        ] == true
        failed <<
          :actor_profile_stable
      end

      if
        strict_behavior_control[
          :work_available
        ] == true ||
        strict_behavior_control[
          :batch_running
        ] == true ||
        strict_behavior_control[
          :stale_running_run
        ] == true
        failed <<
          :actor_behavior_strict_priority
      end

      if
        actor_labels[
          :processing
        ] == true ||
        actor_labels[
          :strict_queue_size
        ].to_i.positive? ||
        actor_labels[
          :strict_worker_busy
        ] == true ||
        actor_labels[
          :lock_present
        ] == true
        failed <<
          :actor_labels_strict_active
      end

      failed.uniq!

      state,
        reason =
          if control[
               :auto_enabled
             ] != true
            [
              :disabled,
              :actor_behavior_heavy_auto_disabled
            ]
          elsif control[
                  :labels_enabled
                ] != true
            [
              :blocked,
              :actor_behavior_heavy_labels_disabled
            ]
          elsif failed.any?
            [
              :blocked,
              failed.first
            ]
          elsif control[
                  :cooldown_active
                ] == true
            [
              :idle,
              :actor_behavior_heavy_cooldown
            ]
          elsif control[
                  :work_available
                ] != true
            [
              :idle,
              :no_actor_behavior_heavy_work
            ]
          else
            [
              :run,
              :actor_behavior_heavy_work_available
            ]
          end

      allowed =
        %i[
          idle
          run
        ].include?(
          state
        )

      resolved_snapshot =
        current_snapshot.merge(
          actor_behavior:
            strict_behavior_control,

          actor_behavior_heavy:
            control
        )

      {
        module:
          :actor_behavior_heavy,

        allowed:
          allowed,

        state:
          state,

        reason:
          reason,

        retry_in:
          if state == :blocked
            60.seconds
          elsif control[
                  :cooldown_active
                ] == true
            control[
              :cooldown_remaining_seconds
            ].to_i.seconds
          end,

        priority:
          priority(
            :actor_behavior_heavy
          ),

        depends_on:
          PIPELINE_REGISTRY.dig(
            :actor_behavior_heavy,
            :depends_on
          ),

        constraints:
          [],

        failed_constraints:
          failed,

        realtime:
          false,

        role:
          :behavioral_resolution,

        architecture_role:
          :behavioral_resolution,

        resources:
          resources(
            :actor_behavior
          ),

        actor_behavior_heavy:
          control.merge(
            blockers:
              failed
          ),

        snapshot:
          resolved_snapshot
      }
    end

    def self.scheduler_only_work_available?(_role)
      false
    end

    def self.tx_outputs_async_work_available?
      Layer1::TxOutputsSpentSync::NextRecord
        .call
        .present?
    rescue StandardError
      true
    end

    def self.tx_output_projection_work_available?
      Layer1::TxOutputProjection::NextRecord
        .call
        .present?
    rescue StandardError
      true
    end

    def self.coverage_work_available?
      snapshot =
        Clusters::Coverage::AddressHealthSnapshot.call

      snapshot[:address_lag].to_i.positive? ||
        snapshot[:null_after].to_i.positive?
    rescue StandardError
      true
    end

    def self.state_for(name, allowed, current_snapshot)
      if name == :bitcoin_core
        return :available if current_snapshot.dig(:bitcoin_core, :available)
        return :unavailable
      end
      if name == :layer1_realtime
        return :processing if current_snapshot.dig(:layer1, :processing)
        return :catching_up if current_snapshot.dig(:layer1, :catching_up)
        return :new_tip_available if current_snapshot.dig(:layer1, :lag).to_i.positive?

        return :synced
      end

      allowed ? :runnable : :waiting
    end

    def self.reason_for_module(name, failed_constraints, current_snapshot)
      if name == :bitcoin_core
        return nil if current_snapshot.dig(:bitcoin_core, :available)
        return :rpc_unavailable
      end
      if name == :layer1_realtime
        return :processing if current_snapshot.dig(:layer1, :processing)
        return :catching_up if current_snapshot.dig(:layer1, :catching_up)
        return :new_tip_available if current_snapshot.dig(:layer1, :lag).to_i.positive?

        return nil
      end

      return nil if failed_constraints.empty?

      reason_for(failed_constraints)
    end

    def self.reason_for(failed_constraints)
      return nil if failed_constraints.empty?

      if failed_constraints.include?(:bitcoin_core_available)
        :bitcoin_core_unavailable

      elsif (
        failed_constraints &
          [
            :layer1_checkpoint_available,
            :layer1_not_processing,
            :layer1_buffers_empty,
            :layer1_strict_queue_idle,
            :layer1_strict_worker_idle,
            :layer1_not_catching_up,
            :strict_io_not_layer1,
            :historical_layer1_lag_within_budget
          ]
      ).any?
        :layer1_realtime_priority

      elsif (
        failed_constraints &
          [
            :cluster_checkpoint_available,
            :cluster_not_processing,
            :cluster_strict_queue_idle,
            :cluster_strict_worker_idle,
            :cluster_caught_up_to_layer1,
            :actor_profile_cluster_lag_within_budget,
            :strict_io_idle,
            :historical_cluster_lag_within_budget
          ]
      ).any?
        :cluster_strict_priority

      elsif failed_constraints.include?(
        :address_spend_projection_available
      )
        :address_spend_projection_unavailable

      elsif failed_constraints.include?(
        :address_spend_projection_ready
      )
        :address_spend_projection_priority

      elsif (
        failed_constraints &
          [
            :actor_profile_checkpoint_available,
            :actor_profile_not_processing,
            :actor_profile_strict_queue_idle,
            :actor_profile_strict_worker_idle,
            :actor_profile_no_pending_work
          ]
      ).any?
        :actor_profile_priority

      elsif failed_constraints.include?(:actor_labels_strict_queue_idle) ||
            failed_constraints.include?(:actor_labels_strict_worker_idle)
        :actor_labels_priority

      else
        failed_constraints.first
      end
    end

    def self.retry_in_for(module_name, failed_constraints)
      return nil if failed_constraints.empty?

      case priority(module_name)
      when 2
        30.seconds
      when 3
        30.seconds
      when 4
        60.seconds
      else
        120.seconds
      end
    end

    def self.priority(module_name)
      PIPELINE_REGISTRY
        .dig(
          canonical_module_name(module_name),
          :priority
        )
    end

    def self.resources(module_name)
      case priority(module_name)
      when 1
        {
          batch_size: :max,
          concurrency: 1
        }
      when 2
        {
          batch_size: :normal,
          concurrency: 1
        }
      when 3
        {
          batch_size: :minimal,
          concurrency: 1
        }
      when 4
        {
          batch_size: :reduced,
          concurrency: 1
        }
      else
        {
          batch_size: :minimal,
          concurrency: 1
        }
      end
    end

    def self.allow_layer1? = allow?(:layer1_realtime)
    def self.allow_layer1_realtime? = allow?(:layer1_realtime)
    def self.allow_cluster? = allow?(:cluster)
    def self.allow_async? = allow?(:actor_profile)
    def self.allow_address_spend_projection? =
      allow?(:address_spend_projection)

    def self.allow_actor_profile? = allow?(:actor_profile)
    def self.allow_actor_behavior? = allow?(:actor_behavior)
    def self.allow_actor_labels? = allow?(:actor_labels)

    # Décision utilisée pendant un lot déjà lancé.
    #
    # Elle ne réévalue pas les conditions de lancement telles que
    # le cooldown ou batch_running. Elle répond uniquement à la
    # question : le travail downstream doit-il céder maintenant
    # devant Layer1 ou Cluster ?
    def self.downstream_preemption_reason(
      module_name,
      current_snapshot: nil
    )
      name =
        canonical_module_name(module_name)

      current_snapshot ||=
        snapshot

      phase_reason =
        development_backfill_preemption_reason(
          name,
          current_snapshot
        )

      return phase_reason if phase_reason

      if development_backfill_mode? &&
         %i[
           actor_behavior
           actor_labels
         ].include?(name)
        return nil if development_backfill_upstream_within_guardrails?(
          current_snapshot
        )

        return :development_backfill_upstream_guardrail
      end

      module_decision =
        decision(
          name,
          current_snapshot: current_snapshot
        )

      return nil if module_decision[:allowed] == true

      reason =
        module_decision[:reason]&.to_sym

      if %i[
        layer1_realtime_priority
        cluster_strict_priority
      ].include?(reason)
        return reason
      end

      failed =
        Array(
          module_decision[:failed_constraints]
        ).map(&:to_sym)

      layer1_constraints = [
        :layer1_checkpoint_available,
        :layer1_not_processing,
        :layer1_buffers_empty,
        :layer1_strict_queue_idle,
        :layer1_strict_worker_idle,
        :layer1_not_catching_up,
        :historical_layer1_lag_within_budget
      ]

      cluster_constraints = [
        :cluster_checkpoint_available,
        :cluster_not_processing,
        :cluster_strict_queue_idle,
        :cluster_strict_worker_idle,
        :cluster_caught_up_to_layer1,
        :historical_cluster_lag_within_budget
      ]

      return :layer1_realtime_priority if (
        failed &
          layer1_constraints
      ).any?

      return :cluster_strict_priority if (
        failed &
          cluster_constraints
      ).any?

      nil
    end
    def self.allow_coverage? = allow?(:coverage)
    def self.allow_layer1_audit? = allow?(:layer1_audit)
    def self.allow_tx_outputs_async? = allow?(:tx_outputs_async)
    def self.allow_tx_output_projection? = allow?(:tx_output_projection)

    def self.failed_constraints(constraints, current_snapshot)
      constraints.reject do |constraint|
        constraint_met?(
          constraint,
          current_snapshot
        )
      end
    end

    def self.constraint_met?(constraint, current_snapshot)
      case constraint.to_sym
      when :bitcoin_core_available
        current_snapshot.dig(
          :bitcoin_core,
          :available
        ) == true

      when :strict_io_idle
        current_snapshot.dig(:strict_io, :owner).blank?

      when :strict_io_not_layer1
        current_snapshot.dig(:strict_io, :owner).to_s != "layer1"

      when :layer1_checkpoint_available
        current_snapshot.dig(:layer1, :checkpoint_available) == true

      when :layer1_not_processing
        current_snapshot.dig(:layer1, :processing) != true

      when :layer1_buffers_empty
        current_snapshot.dig(:layer1, :buffers_empty) == true

      when :historical_layer1_lag_within_budget
        current_snapshot
          .dig(:layer1, :lag)
          .to_i <=
          Layer1::HistoricalWorkConfig
            .max_layer1_lag_blocks

      when :actor_profile_layer1_lag_within_budget
        current_snapshot
          .dig(:layer1, :lag)
          .to_i <= ACTOR_PROFILE_MAX_LAYER1_LAG

      when :development_backfill_upstream_within_guardrails
        development_backfill_upstream_within_guardrails?(
          current_snapshot
        )

      when :layer1_strict_queue_idle
        current_snapshot.dig(:layer1, :strict_queue_size).to_i.zero?

      when :layer1_strict_worker_idle
        current_snapshot.dig(:layer1, :strict_worker_busy) != true

      when :layer1_not_catching_up
        current_snapshot.dig(:layer1, :catching_up) != true

      when :cluster_layer1_lag_within_budget
        current_snapshot
          .dig(:layer1, :lag)
          .to_i <= CLUSTER_MAX_LAYER1_LAG

      when :cluster_checkpoint_available
        current_snapshot.dig(:cluster, :checkpoint_available) == true

      when :historical_cluster_lag_within_budget
        current_snapshot
          .dig(:cluster, :lag)
          .to_i <=
          Layer1::HistoricalWorkConfig
            .max_cluster_lag_blocks

      when :actor_profile_cluster_lag_within_budget
        cluster_lag_for(
          current_snapshot
        ) <= ACTOR_PROFILE_MAX_CLUSTER_LAG

      when :actor_profile_cluster_global_lag_within_budget
        global_lag =
          current_snapshot.dig(:cluster, :global_lag)

        global_lag ||=
          [
            current_snapshot.dig(:bitcoin_core, :best_height).to_i -
              current_snapshot.dig(:cluster, :processed_height).to_i,
            0
          ].max

        global_lag.to_i <= ACTOR_PROFILE_MAX_CLUSTER_GLOBAL_LAG

      when :cluster_not_processing
        current_snapshot.dig(:cluster, :processing) != true

      when :cluster_strict_queue_idle
        current_snapshot.dig(:cluster, :strict_queue_size).to_i.zero?

      when :cluster_strict_worker_idle
        current_snapshot.dig(:cluster, :strict_worker_busy) != true

      when :cluster_caught_up_to_layer1
        current_snapshot.dig(:cluster, :caught_up_to_layer1) == true

      when :address_spend_projection_available
        projection =
          current_snapshot[
            :address_spend_projection
          ] || {}

        projection[:available] == true

      when :address_spend_projection_ready
        projection =
          current_snapshot[
            :address_spend_projection
          ] || {}

        projection[:available] == true &&
          projection[
            :caught_up_to_cluster
          ] == true &&
          projection[:failed] != true

      when :actor_profile_checkpoint_available
        current_snapshot.dig(:actor_profile, :checkpoint_available) == true

      when :actor_profile_not_processing
        current_snapshot.dig(:actor_profile, :processing) != true

      when :actor_profile_strict_queue_idle
        current_snapshot.dig(:actor_profile, :strict_queue_size).to_i.zero?

      when :actor_profile_strict_worker_idle
        current_snapshot.dig(:actor_profile, :strict_worker_busy) != true

      when :actor_profile_no_pending_work
        current_snapshot.dig(:actor_profile, :pending_work).to_i.zero? &&
          current_snapshot.dig(:actor_profile, :caught_up_to_cluster) == true

      when :actor_labels_strict_queue_idle
        current_snapshot.dig(:actor_labels, :strict_queue_size).to_i.zero?

      when :actor_labels_strict_worker_idle
        current_snapshot.dig(:actor_labels, :strict_worker_busy) != true

      else
        false
      end
    end

    def self.development_backfill_alternating_enabled?(
      current_snapshot
    )
      control =
        current_snapshot[
          :development_backfill
        ] || {}

      control[:enabled] == true &&
        control[:config_valid] == true &&
        %w[
          downstream_catchup
          layer1_catchup
        ].include?(
          control[:phase].to_s
        )
    end

    def self.development_backfill_phase_decision(
      name,
      config,
      current_snapshot
    )
      return nil unless
        development_backfill_alternating_enabled?(
          current_snapshot
        )

      phase =
        current_snapshot.dig(
          :development_backfill,
          :phase
        ).to_s

      reason =
        if name == :layer1_realtime &&
           phase == "downstream_catchup"
          :development_backfill_downstream_catchup

        elsif DEVELOPMENT_BACKFILL_DOWNSTREAM_MODULES
                .include?(name) &&
              phase == "layer1_catchup"
          :development_backfill_layer1_catchup
        end

      return nil unless reason

      {
        module: name,
        allowed: false,
        state: :waiting,
        reason: reason,
        retry_in: 10.seconds,
        priority: config[:priority],
        depends_on: config[:depends_on],
        constraints:
          constraints_for(
            name,
            config
          ),
        failed_constraints: [reason],
        realtime: config[:realtime],
        role: config[:role],
        architecture_role: config[:role],
        resources: resources(name),
        snapshot: current_snapshot
      }
    end

    def self.development_backfill_preemption_reason(
      name,
      current_snapshot
    )
      return nil unless
        development_backfill_alternating_enabled?(
          current_snapshot
        )

      return nil unless
        current_snapshot.dig(
          :development_backfill,
          :phase
        ).to_s == "layer1_catchup"

      return nil unless
        DEVELOPMENT_BACKFILL_DOWNSTREAM_MODULES
          .include?(name)

      :development_backfill_layer1_catchup
    end

    def self.pipeline_mode
      ENV.fetch(
        PIPELINE_MODE_ENV,
        "realtime"
      ).to_s
    end

    def self.development_backfill_mode?
      pipeline_mode == DEVELOPMENT_BACKFILL_MODE
    end

    def self.development_backfill_max_layer1_lag
      Integer(
        ENV.fetch(
          BACKFILL_MAX_LAYER1_LAG_ENV,
          "20"
        )
      )
    rescue ArgumentError, TypeError
      20
    end

    def self.development_backfill_max_cluster_global_lag
      Integer(
        ENV.fetch(
          BACKFILL_MAX_CLUSTER_GLOBAL_LAG_ENV,
          "30"
        )
      )
    rescue ArgumentError, TypeError
      30
    end

    def self.constraints_for(name, config)
      return config[:constraints] unless development_backfill_mode?

      case name
      when :cluster
        DEVELOPMENT_BACKFILL_CLUSTER_CONSTRAINTS

      when :address_spend_projection
        DEVELOPMENT_BACKFILL_ADDRESS_SPEND_CONSTRAINTS

      when :actor_profile
        DEVELOPMENT_BACKFILL_ACTOR_PROFILE_CONSTRAINTS

      else
        config[:constraints]
      end
    end

    def self.cluster_lag_for(current_snapshot)
      value =
        current_snapshot.dig(
          :cluster,
          :lag
        )

      return [
        value.to_i,
        0
      ].max unless value.nil?

      [
        current_snapshot.dig(
          :layer1,
          :processed_height
        ).to_i -
          current_snapshot.dig(
            :cluster,
            :processed_height
          ).to_i,
        0
      ].max
    end

    def self.cluster_global_lag_for(current_snapshot)
      value =
        current_snapshot.dig(
          :cluster,
          :global_lag
        )

      return value.to_i unless value.nil?

      [
        current_snapshot.dig(
          :bitcoin_core,
          :best_height
        ).to_i -
          current_snapshot.dig(
            :cluster,
            :processed_height
          ).to_i,
        0
      ].max
    end

    def self.development_backfill_upstream_within_guardrails?(
      current_snapshot
    )
      current_snapshot.dig(
        :layer1,
        :checkpoint_available
      ) == true &&
        current_snapshot.dig(
          :cluster,
          :checkpoint_available
        ) == true &&
        current_snapshot.dig(
          :layer1,
          :lag
        ).to_i <= development_backfill_max_layer1_lag &&
        cluster_global_lag_for(
          current_snapshot
        ) <= development_backfill_max_cluster_global_lag
    end

    def self.development_backfill_downstream_decision(
      decision,
      current_snapshot:
    )
      return decision unless development_backfill_mode?

      failed =
        Array(
          decision[:failed_constraints]
        ).map(&:to_sym)

      downstream_priority_block =
        [
          :layer1_realtime_priority,
          :cluster_strict_priority,
          :actor_profile_priority
        ].include?(
          decision[:reason]&.to_sym
        ) ||
        (
          failed.any? &&
          failed.all? do |constraint|
            value =
              constraint.to_s

            value.start_with?("actor_profile_") ||
              value.start_with?("layer1_") ||
              value.start_with?("cluster_") ||
              value.start_with?("historical_layer1_") ||
              value.start_with?("historical_cluster_")
          end
        )

      within_guardrails =
        development_backfill_upstream_within_guardrails?(
          current_snapshot
        )

      if !within_guardrails &&
         (
           decision[:allowed] == true ||
           downstream_priority_block
         )
        return decision.merge(
          allowed: false,
          state: :waiting,
          reason: :development_backfill_upstream_guardrail,
          retry_in: 30.seconds,
          failed_constraints:
            (
              failed +
              [
                :development_backfill_upstream_within_guardrails
              ]
            ).uniq
        )
      end

      return decision unless downstream_priority_block

      incremental_work_available =
        case decision[:module]
        when :actor_behavior
          decision.dig(
            :actor_behavior,
            :auto_enabled
          ) == true &&
            decision.dig(
              :actor_behavior,
              :work_available
            ) == true &&
            decision.dig(
              :actor_behavior,
              :cooldown_active
            ) != true &&
            decision.dig(
              :actor_behavior,
              :batch_running
            ) != true &&
            decision.dig(
              :actor_behavior,
              :stale_running_run
            ) != true

        when :actor_labels
          decision.dig(
            :actor_labels,
            :work_available
          ) == true &&
            decision.dig(
              :actor_labels,
              :cooldown_active
            ) != true &&
            decision.dig(
              :actor_labels,
              :lock_present
            ) != true &&
            decision.dig(
              :actor_labels,
              :worker_write_enabled
            ) != false

        else
          false
        end

      return decision unless incremental_work_available

      decision.merge(
        allowed: true,
        state: :run,
        reason: nil,
        retry_in: nil,
        failed_constraints: []
      )
    end

    def self.unknown_module_decision(name)
      {
        module: name,
        allowed: false,
        state: :blocked,
        reason: :unknown_module,
        retry_in: nil,
        priority: nil,
        depends_on: [],
        constraints: [],
        failed_constraints: [:unknown_module],
        realtime: false,
        role: nil,
        architecture_role: nil,
        resources: resources(name),
        snapshot: snapshot
      }
    end

    def self.canonical_module_name(module_name)
      name = module_name.to_sym

      ROLE_ALIASES.fetch(name, name)
    end

    def self.layer1_heavy_decision(role, current_snapshot: nil)
      decision(role, current_snapshot: current_snapshot)
    end

    def self.actor_behavior_decision(current_snapshot: nil)
      control =
        current_snapshot&.dig(:actor_behavior) ||
        ActorBehaviors::ControlSnapshot.call

      actor_profile =
        current_snapshot&.dig(:actor_profile) || {}

      state, reason, failed =
        actor_behavior_state_reason_constraints(
          control: control,
          actor_profile: actor_profile,
          current_snapshot: current_snapshot || {}
        )

      allowed =
        %i[idle run].include?(state)

      snapshot =
        (current_snapshot || {}).merge(
          actor_behavior: control
        )

      {
        module: :actor_behavior,
        allowed: allowed,
        state: state,
        reason: reason,
        retry_in: allowed ? nil : 60.seconds,
        priority: priority(:actor_behavior),
        depends_on: PIPELINE_REGISTRY.dig(:actor_behavior, :depends_on),
        constraints: [],
        failed_constraints: failed,
        realtime: false,
        role: :behavior_builder,
        architecture_role: :behavior_builder,
        resources: resources(:actor_behavior),
        actor_behavior: {
          mode: control[:mode],
          auto_enabled: control[:auto_enabled],
          local_auto_enabled: control[:local_auto_enabled],
          scheduler_present: control[:scheduler_present],
          scheduler_runtime_fresh: control[:scheduler_runtime_fresh],
          scheduler_actor_behavior_auto_enabled:
            control[:scheduler_actor_behavior_auto_enabled],
          scheduler_enabled: control[:scheduler_enabled],
          behavior_version: control[:behavior_version],
          certified_profiles_available:
            control[:certified_profiles_available],
          work_available: control[:work_available],
          missing_work_available:
            control[:missing_work_available],
          stale_work_available:
            control[:stale_work_available],
          batch_running: control[:batch_running],
          stale_running_run:
            control[:stale_running_run],
          last_run_status:
            control[:last_run_status],
          last_run_finished_at:
            control[:last_run_finished_at],
          min_interval_seconds:
            control[:min_interval_seconds],
          last_terminal_run_finished_at:
            control[:last_terminal_run_finished_at],
          next_eligible_at:
            control[:next_eligible_at],
          cooldown_active:
            control[:cooldown_active],
          cooldown_remaining_seconds:
            control[:cooldown_remaining_seconds]
        },
        snapshot: snapshot
      }
    end

    def self.actor_behavior_state_reason_constraints(
      control:,
      actor_profile:,
      current_snapshot:
    )
      upstream_failed =
        failed_constraints(
          STRICT_UPSTREAM_CONSTRAINTS,
          current_snapshot
        )

      if upstream_failed.any?
        return [
          :blocked,
          reason_for(upstream_failed),
          upstream_failed
        ]
      end

      unless control[:auto_enabled] == true
        return [
          :disabled,
          :actor_behavior_auto_disabled,
          [:actor_behavior_auto_enabled]
        ]
      end

      if actor_profile.key?(:checkpoint_available) &&
         actor_profile[:checkpoint_available] != true
        return [
          :blocked,
          :actor_profile_unavailable,
          [:actor_profile_checkpoint_available]
        ]
      end

      unless control[:certified_profiles_available] == true
        return [
          :blocked,
          :no_certified_actor_profiles,
          [:certified_actor_profiles_available]
        ]
      end

      if control[:stale_running_run] == true
        return [
          :blocked,
          :stale_actor_behavior_run,
          [:actor_behavior_no_stale_running_run]
        ]
      end

      if control[:batch_running] == true
        return [
          :blocked,
          :actor_behavior_batch_running,
          [:actor_behavior_batch_not_running]
        ]
      end

      unless control[:work_available] == true
        return [
          :idle,
          :no_actor_behavior_work,
          []
        ]
      end

      if control[:cooldown_active] == true
        return [
          :idle,
          :actor_behavior_cooldown,
          [:actor_behavior_cooldown_elapsed]
        ]
      end

      [
        :run,
        :actor_behavior_work_available,
        []
      ]
    end

    def self.actor_labels_decision(current_snapshot: nil)
      control =
        current_snapshot&.dig(:actor_labels) ||
        ActorLabels::ControlSnapshot.call

      actor_behavior =
        current_snapshot&.dig(:actor_behavior) ||
        ActorBehaviors::ControlSnapshot.call

      actor_profile =
        current_snapshot&.dig(:actor_profile) || {}

      state, reason, failed =
        actor_labels_state_reason_constraints(
          control: control,
          actor_behavior: actor_behavior,
          actor_profile: actor_profile,
          current_snapshot: current_snapshot || {}
        )

      allowed =
        %i[idle run].include?(state)

      snapshot =
        (current_snapshot || {}).merge(
          actor_labels: control,
          actor_behavior: actor_behavior
        )

      {
        module: :actor_labels,
        allowed: allowed,
        state: state,
        reason: reason,
        retry_in: state == :blocked ? 60.seconds : nil,
        priority: priority(:actor_labels),
        depends_on: PIPELINE_REGISTRY.dig(:actor_labels, :depends_on),
        constraints: [],
        failed_constraints: failed,
        realtime: false,
        role: :label_builder,
        architecture_role: :label_builder,
        resources: resources(:actor_labels),
        actor_labels: {
          source: control[:source],
          rule_version: control[:rule_version],
          required_behavior_version:
            control[:required_behavior_version],
          queue_name: control[:queue_name],
          queue_size: control[:queue_size],
          scheduled_size: control[:scheduled_size],
          worker_busy: control[:worker_busy],
          worker_present: control[:worker_present],
          lock_present: control[:lock_present],
          cursor: control[:cursor],
          work_available: control[:work_available],
          pending_for_labels: control[:pending_for_labels],
          cooldown_active: control[:cooldown_active],
          cooldown_remaining_seconds:
            control[:cooldown_remaining_seconds],
          next_eligible_at: control[:next_eligible_at],
          last_run_status: control[:last_run_status],
          last_run_finished_at:
            control[:last_run_finished_at],
          last_runtime_ms: control[:last_runtime_ms]
        },
        snapshot: snapshot
      }
    end

    def self.actor_labels_state_reason_constraints(
      control:,
      actor_behavior:,
      actor_profile:,
      current_snapshot:
    )
      upstream_failed =
        failed_constraints(
          STRICT_UPSTREAM_CONSTRAINTS,
          current_snapshot
        )

      if upstream_failed.any?
        return [
          :blocked,
          reason_for(upstream_failed),
          upstream_failed
        ]
      end

      if actor_profile[:processing] == true ||
         actor_profile[:strict_worker_busy] == true
        return [
          :blocked,
          :actor_profile_priority,
          [:actor_profile_not_processing]
        ]
      end

      if actor_profile[:pending_work].to_i.positive? ||
         actor_profile[:caught_up_to_cluster] == false
        return [
          :blocked,
          :actor_profile_priority,
          [:actor_profile_no_pending_work]
        ]
      end

      unless actor_behavior[:certified_profiles_available] == true
        return [
          :blocked,
          :actor_behavior_unavailable,
          [:actor_behavior_certified_profiles_available]
        ]
      end

      if control[:lock_present] == true ||
         control[:worker_busy] == true ||
         control[:queue_size].to_i.positive? ||
         control[:scheduled_size].to_i.positive?
        return [
          :blocked,
          :actor_labels_batch_present,
          [:actor_labels_single_batch]
        ]
      end

      unless control[:work_available] == true
        return [
          :idle,
          :no_actor_labels_work,
          []
        ]
      end

      if control[:cooldown_active] == true
        return [
          :idle,
          :actor_labels_cooldown,
          [:actor_labels_cooldown_elapsed]
        ]
      end

      [
        :run,
        :actor_labels_work_available,
        []
      ]
    end

    def self.layer1_catching_up?(
      lag:,
      processing:,
      buffers_empty:,
      strict_queue_size:,
      strict_worker_busy:
    )
      return true if processing
      return true unless buffers_empty
      return true if strict_queue_size.to_i.positive?
      return true if strict_worker_busy

      lag.to_i > 1
    end

    def self.address_spend_projection_snapshot(
      cluster_processed:
    )
      source =
        AddressSpendStats::
          OperationalSnapshot.call

      sync =
        source[:sync] || {}

      activity =
        source[:activity] || {}

      automation =
        source[:automation] || {}

      projection_height =
        sync[
          :projection_tip
        ].to_i

      next_record_height =
        sync[
          :next_record_height
        ]

      worker_present =
        automation[
          :process_present
        ] == true

      source_available =
        source[:available] == true

      failed =
        source[
          :failed_checkpoint
        ].present?

      {
        available:
          source_available &&
          worker_present,

        source_available:
          source_available,

        worker_present:
          worker_present,

        migration_pending:
          source[
            :migration_pending
          ] == true,

        checkpoint_height:
          projection_height,

        checkpoint_available:
          projection_height.positive?,

        caught_up_to_cluster:
          sync[
            :caught_up_to_cluster
          ] == true &&
          projection_height >=
            cluster_processed.to_i,

        lag:
          sync[:lag],

        next_record_height:
          next_record_height,

        work_available:
          next_record_height.present?,

        processing:
          activity[
            :processing_height
          ].present? ||
          automation[
            :busy_workers
          ].to_i.positive?,

        processing_height:
          activity[
            :processing_height
          ],

        strict_queue_size:
          automation[
            :queue_size
          ].to_i,

        strict_worker_busy:
          automation[
            :busy_workers
          ].to_i.positive?,

        strict_active:
          automation[
            :queue_size
          ].to_i.positive? ||
          automation[
            :busy_workers
          ].to_i.positive?,

        failed:
          failed,

        status:
          source[:status]
      }
    rescue StandardError
      {
        available: false,
        source_available: false,
        worker_present: false,
        migration_pending: false,
        checkpoint_height: 0,
        checkpoint_available: false,
        caught_up_to_cluster: false,
        lag: nil,
        next_record_height: nil,
        work_available: false,
        processing: false,
        processing_height: nil,
        strict_queue_size:
          sidekiq_queue_size(
            ADDRESS_SPEND_PROJECTION_QUEUE
          ),
        strict_worker_busy:
          sidekiq_worker_busy?(
            ADDRESS_SPEND_PROJECTION_QUEUE
          ),
        strict_active: false,
        failed: true,
        status: "unavailable"
      }
    end

    def self.actor_profile_snapshot(cluster_processed:)
      source =
        ActorProfiles::OperationalSnapshot.read

      progress =
        source[:progress] || {}

      certification =
        source[:certification] || {}

      automation =
        source[:automation] || {}

      epoch_active =
        certification[:epoch_active] == true

      epoch_height =
        certification[
          :certification_epoch_height
        ].to_i

      pending =
        if progress.key?(
          :pending_profiles_since_epoch
        )
          progress[
            :pending_profiles_since_epoch
          ].to_i
        else
          progress[
            :pending_profiles
          ].to_i
        end

      queue_size =
        automation[:queue_size].to_i

      worker_busy =
        automation[
          :busy_workers
        ].to_i.positive?

      lock_present =
        automation[
          :lock_ttl
        ].to_i.positive?

      processing =
        worker_busy ||
        lock_present

      caught_up =
        epoch_active &&
        pending.zero? &&
        !processing

      {
        epoch_active:
          epoch_active,

        certification_epoch_height:
          epoch_active ?
            epoch_height :
            nil,

        checkpoint_height:
          epoch_active ?
            epoch_height :
            0,

        checkpoint_available:
          epoch_active &&
          epoch_height.positive?,

        caught_up_to_cluster:
          caught_up,

        pending_work:
          epoch_active ?
            pending :
            0,

        processing:
          processing,

        strict_queue_size:
          queue_size,

        strict_worker_busy:
          worker_busy,

        strict_active:
          queue_size.positive? ||
          processing
      }
    rescue StandardError
      {
        epoch_active:
          false,

        certification_epoch_height:
          nil,

        checkpoint_height:
          0,

        checkpoint_available:
          false,

        caught_up_to_cluster:
          false,

        pending_work:
          0,

        processing:
          false,

        strict_queue_size:
          sidekiq_queue_size(
            ACTOR_PROFILE_STRICT_QUEUE
          ),

        strict_worker_busy:
          sidekiq_worker_busy?(
            ACTOR_PROFILE_STRICT_QUEUE
          ),

        strict_active:
          false
      }
    end

    def self.actor_labels_snapshot
      control =
        ActorLabels::ControlSnapshot.call

      control.merge(
        checkpoint_available: true,
        processing:
          control[:worker_busy] == true ||
          control[:lock_present] == true,
        strict_queue_size: control[:queue_size].to_i,
        strict_worker_busy: control[:worker_busy] == true,
        scheduled_marker_present:
          redis_key_present?(ActorLabels::StrictBatchJob::SCHEDULE_KEY),
        strict_active:
          control[:queue_size].to_i.positive? ||
          control[:worker_busy] == true ||
          control[:lock_present] == true ||
          control[:scheduled_size].to_i.positive?
      )
    rescue StandardError
      {
        checkpoint_available: true,
        processing: false,
        strict_queue_size: sidekiq_queue_size(ACTOR_LABELS_STRICT_QUEUE),
        strict_worker_busy: sidekiq_worker_busy?(ACTOR_LABELS_STRICT_QUEUE),
        scheduled_marker_present: false,
        strict_active: false
      }
    end

    def self.sidekiq_queue_size(name)
      require "sidekiq/api"

      Sidekiq::Queue.new(name).size
    rescue StandardError
      0
    end

    def self.sidekiq_worker_busy?(queue_name)
      require "sidekiq/api"

      Sidekiq::ProcessSet.new.any? do |process|
        Array(process["queues"]).include?(queue_name) &&
          process["busy"].to_i.positive?
      end
    rescue StandardError
      false
    end

    def self.sidekiq_work_active?(queue_name:, job_class:)
      require "sidekiq/api"
      require "json"

      Sidekiq::WorkSet.new.any? do |_process_id, _thread_id, work|
        payload =
          sidekiq_work_payload(work)

        payload["queue"].to_s == queue_name.to_s &&
          sidekiq_payload_job_class(payload).to_s == job_class.to_s
      end
    rescue StandardError
      false
    end

    def self.sidekiq_work_payload(work)
      raw =
        if work.respond_to?(:payload)
          work.payload
        else
          work.instance_variable_get(:@hsh)
        end

      case raw
      when Hash
        raw
      when String
        JSON.parse(raw)
      else
        {}
      end
    end

    def self.sidekiq_payload_job_class(payload)
      first_arg =
        Array(payload["args"]).first

      if first_arg.is_a?(Hash)
        first_arg["job_class"] ||
          first_arg["wrapped"] ||
          payload["class"]
      else
        payload["class"]
      end
    end

    def self.redis_key_present?(key)
      Sidekiq.redis do |redis|
        redis.exists?(key)
      end
    rescue StandardError
      false
    end
  end
end
