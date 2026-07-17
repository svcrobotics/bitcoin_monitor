# frozen_string_literal: true

module Layer1
  class DashboardSnapshot
    RECENT_BLOCKS_LIMIT = 5
    AVERAGE_BLOCKS_LIMIT = 10
    RECENT_ROWS_LIMIT = AVERAGE_BLOCKS_LIMIT + 1

    def self.call(
      snapshot:,
      overview: nil
    )
      new(
        snapshot: snapshot,
        overview: overview
      ).call
    end

    def initialize(
      snapshot:,
      overview: nil
    )
      @raw_snapshot =
        overview.presence ||
        snapshot ||
        {}

      @raw_snapshot =
        @raw_snapshot.with_indifferent_access if
          @raw_snapshot.respond_to?(
            :with_indifferent_access
          )

      @overview =
        if raw_source ==
           "layer1_overview_snapshot"
          @raw_snapshot
        else
          {}.with_indifferent_access
        end
    end

    def call
      recent_rows = recent_processed_rows
      recent_blocks = build_recent_blocks(recent_rows)
      last_row = recent_rows.first
      baseline_rows = recent_rows.drop(1).first(AVERAGE_BLOCKS_LIMIT)

      sync = sync_snapshot
      buffers = buffers_snapshot
      current_block = current_block_snapshot
      proof = proof_snapshot
      pipeline = pipeline_snapshot(
        sync: sync,
        buffers: buffers,
        current_block: current_block
      )
      automation = automation_snapshot(
        pipeline: pipeline,
        current_block: current_block
      )
      historical_projection = historical_projection_snapshot(sync: sync)

      {
        source: "layer1_dashboard_snapshot",
        generated_at:
          overview_value(:generated_at) ||
          Time.current,

        status: normalized_status,
        status_label: status_label,
        status_summary: status_summary(
          sync: sync,
          buffers: buffers,
          current_block: current_block,
          proof: proof
        ),
        sync: sync,
        buffers: buffers,
        pipeline: pipeline,
        automation: automation,
        historical_projection: historical_projection,
        current_block: current_block,
        performance: performance_snapshot(
          recent_blocks: recent_blocks,
          last_height: last_row&.fetch(:height),
          last_duration_ms: last_row&.fetch(:duration_ms),
          average_duration_ms: average_duration(baseline_rows),
          average_blocks_count: baseline_rows.size
        ),
        proof: proof,

        audit:
          overview_section(
            :audit
          ),

        pace:
          overview_section(
            :pace
          ),
        counts: value(snapshot, :counts) || {},
        cursors: value(snapshot, :cursors) || {},
        timestamps: value(snapshot, :timestamps) || {},
        queues: value(snapshot, :queues) || {}
      }
    end

    private

    attr_reader :overview

    def snapshot
      @snapshot ||=
        begin
          realtime =
            if raw_source ==
               "layer1_overview_snapshot"
              raw_value(
                @raw_snapshot,
                :realtime
              ) || {}
            else
              @raw_snapshot
            end

          if realtime.respond_to?(
               :with_indifferent_access
             )
            realtime.with_indifferent_access
          else
            realtime
          end
        end
    end

    def raw_source
      raw_value(
        @raw_snapshot,
        :source
      ).to_s
    end

    def raw_value(hash, key)
      return nil unless
        hash.respond_to?(
          :key?
        )

      return hash[key] if
        hash.key?(
          key
        )

      hash[
        key.to_s
      ]
    end

    def normalized_status
      value(snapshot, :status).to_s.presence || "unknown"
    end

    def status_label
      case normalized_status
      when "healthy"
        "Synchronisé et opérationnel"
      when "warning"
        "Opérationnel sous surveillance"
      when "critical"
        "Intervention requise"
      else
        "État indéterminé"
      end
    end

    def status_summary(sync:, buffers:, current_block:, proof:)
      case normalized_status
      when "healthy"
        healthy_status_summary(
          sync: sync,
          buffers: buffers,
          current_block: current_block,
          proof: proof
        )
      when "warning"
        warning_status_summary(
          sync: sync,
          buffers: buffers,
          current_block: current_block,
          proof: proof
        )
      when "critical"
        "Layer1 ne remplit pas actuellement toutes les conditions de confiance du pipeline strict."
      else
        "Les informations disponibles ne permettent pas encore d’établir un verdict complet."
      end
    end

    def warning_status_summary(sync:, buffers:, current_block:, proof:)
      sentences = []

      if current_block&.dig(:height).present?
        sentences <<
          "Layer1 reste opérationnel et traite actuellement le bloc " \
          "#{formatted_integer(current_block[:height])}."
      else
        sentences << "Layer1 reste opérationnel."
      end

      reasons = warning_reasons(sync: sync, buffers: buffers)

      if reasons.one?
        sentences << "Le signal sous surveillance est #{reasons.first}."
      elsif reasons.many?
        sentences << "Les signaux sous surveillance sont #{reasons.to_sentence}."
      else
        sentences << "Un indicateur technique demande encore une surveillance."
      end

      if proof[:total_checks].to_i.positive?
        sentences <<
          if proof[:conformant]
            "Le dernier audit reste conforme " \
              "(#{proof[:passed_checks]}/#{proof[:total_checks]} contrôles)."
          else
            "Le dernier audit présente " \
              "#{proof[:passed_checks]}/#{proof[:total_checks]} contrôles conformes."
          end
      end

      sentences.join(" ")
    end

    def warning_reasons(sync:, buffers:)
      reasons = []
      activity = value(snapshot, :activity) || {}
      lag = sync[:lag].to_i

      if lag > 1
        reasons <<
          "un retard de #{blocks_label(lag)} sur Bitcoin Core, " \
          "actuellement en cours de résorption"
      end

      if buffers[:outputs].to_i > 200_000
        reasons <<
          "un buffer outputs de #{formatted_integer(buffers[:outputs])} éléments"
      end

      if buffers[:spent].to_i > 50_000
        reasons <<
          "un buffer spent de #{formatted_integer(buffers[:spent])} éléments"
      end

      layer1_drain_queue = value(activity, :layer1_drain_queue).to_i
      if layer1_drain_queue > 10
        reasons <<
          "#{formatted_integer(layer1_drain_queue)} travaux dans la file Layer1 drain"
      end

      spent_resolve_queue = value(activity, :spent_resolve_queue).to_i
      if spent_resolve_queue > 500
        reasons <<
          "#{formatted_integer(spent_resolve_queue)} résolutions de dépenses en attente"
      end

      reasons
    end

    def healthy_status_summary(sync:, buffers:, current_block:, proof:)
      lag = sync[:lag].to_i
      sentences = []

      if lag.zero?
        sentences << "Layer1 a certifié le dernier bloc disponible sur Bitcoin Core."
      elsif current_block&.dig(:height).present?
        sentences <<
          "Layer1 suit Bitcoin Core avec un retard normal de #{blocks_label(lag)}, " \
          "correspondant au bloc #{formatted_integer(current_block[:height])} en cours de traitement."
      else
        sentences <<
          "Layer1 reste opérationnel et résorbe actuellement un retard de #{blocks_label(lag)}."
      end

      buffered_items = buffers[:outputs].to_i + buffers[:spent].to_i

      if buffered_items.zero?
        sentences << "Les buffers temps réel sont vides."
      else
        sentences <<
          "Les buffers temps réel contiennent #{formatted_integer(buffered_items)} " \
          "élément#{'s' unless buffered_items == 1} en cours de traitement."
      end

      if proof[:total_checks].to_i.positive?
        sentences <<
          if proof[:conformant]
            "Le dernier audit disponible est conforme " \
              "(#{proof[:passed_checks]}/#{proof[:total_checks]} contrôles)."
          else
            "Le dernier audit disponible présente " \
              "#{proof[:passed_checks]}/#{proof[:total_checks]} contrôles conformes."
          end
      end

      sentences.join(" ")
    end

    def sync_snapshot
      legacy_sync = value(snapshot, :sync) || {}

      bitcoin_core_height =
        value(snapshot, :bitcoin_core_height) ||
        value(snapshot, :best_height) ||
        value(legacy_sync, :best_height)

      processed_height =
        value(snapshot, :processed_height) ||
        value(legacy_sync, :processed_height)

      lag =
        value(snapshot, :lag)

      lag =
        value(legacy_sync, :lag) if lag.nil?

      lag =
        if lag.nil? && bitcoin_core_height && processed_height
          [bitcoin_core_height.to_i - processed_height.to_i, 0].max
        else
          lag
        end

      {
        bitcoin_core_height: bitcoin_core_height,
        processed_height: processed_height,
        lag: lag.to_i
      }
    end

    def buffers_snapshot
      buffers = value(snapshot, :buffers) || {}

      {
        outputs: value(buffers, :outputs).to_i,
        spent: value(buffers, :spent).to_i
      }
    end

    def pipeline_snapshot(sync:, buffers:, current_block:)
      activity = value(snapshot, :activity) || {}
      state = value(activity, :pipeline_state).to_s.presence || "unknown"

      label, description =
        case state
        when "idle_synced"
          [
            "À jour — en attente du prochain bloc",
            "Le pipeline est synchronisé. L’absence de worker actif est normale : aucun bloc ne nécessite de traitement."
          ]
        when "active"
          active_pipeline_copy(
            sync: sync,
            buffers: buffers,
            current_block: current_block
          )
        when "blocked_failed"
          [
            "Bloqué par un bloc en échec",
            "Un bloc a échoué et empêche la progression continue du pipeline."
          ]
        when "blocked_stale_processing"
          [
            "Traitement sans progression",
            "Un bloc est marqué en cours mais son heartbeat est trop ancien."
          ]
        when "blocked_no_worker"
          [
            "Worker absent",
            "Aucun processus Sidekiq n’écoute actuellement la queue Layer1 stricte."
          ]
        when "blocked_no_scheduler", "blocked_no_scheduler_process"
          [
            "Scheduler indisponible",
            "Le mécanisme indépendant chargé de relancer Layer1 n’est pas complètement opérationnel."
          ]
        when "blocked_orphaned_lock"
          [
            "Verrou orphelin",
            "Un verrou empêche le redémarrage alors qu’aucun worker n’exécute le pipeline."
          ]
        else
          [
            state.humanize,
            "État technique transmis par le pipeline Layer1."
          ]
        end

      {
        state: state,
        label: label,
        description: description
      }
    end

    def active_pipeline_copy(sync:, buffers:, current_block:)
      lag = sync[:lag].to_i
      buffered_items = buffers[:outputs].to_i + buffers[:spent].to_i

      if current_block&.dig(:height).present?
        height = formatted_integer(current_block[:height])
        details = ["Layer1 traite actuellement le bloc #{height}."]

        if buffered_items.zero?
          details << "Les buffers temps réel sont vides."
        else
          details <<
            "Les buffers temps réel contiennent #{formatted_integer(buffered_items)} " \
            "élément#{'s' unless buffered_items == 1} en cours de traitement."
        end

        if lag == 1
          details << "Le retard d’un bloc correspond au bloc en cours de certification."
        elsif lag > 1
          details << "Le retard de #{blocks_label(lag)} est en cours de résorption."
        end

        ["Bloc #{height} en cours de traitement", details.join(" ")]
      elsif lag.positive?
        [
          "Rattrapage en cours",
          "Layer1 résorbe actuellement un retard de #{blocks_label(lag)} sur Bitcoin Core."
        ]
      elsif buffered_items.positive?
        [
          "Vidage des buffers en cours",
          "Layer1 finalise #{formatted_integer(buffered_items)} " \
            "élément#{'s' unless buffered_items == 1} encore présent#{'s' unless buffered_items == 1} dans les buffers temps réel."
        ]
      else
        [
          "Travail Layer1 en cours",
          "Un travail du pipeline strict est actuellement exécuté ou en attente de finalisation."
        ]
      end
    end

    def automation_snapshot(pipeline:, current_block:)
      strict = value(snapshot, :strict) || {}
      scheduler = value(strict, :scheduler) || {}
      scheduler_process = value(strict, :scheduler_process) || {}
      worker = value(strict, :worker) || {}

      worker_present =
        truthy?(value(worker, :present))

      worker_busy =
        value(worker, :busy).to_i

      pipeline_state = pipeline[:state]

      worker_label =
        if pipeline_state == "blocked_stale_processing"
          "Heartbeat expiré"
        elsif current_block.present? && pipeline_state == "active"
          "En traitement"
        elsif worker_busy.positive?
          "En traitement"
        elsif worker_present && pipeline_state == "idle_synced"
          "Au repos — aucun travail en attente"
        elsif worker_present
          "Disponible"
        else
          "Absent"
        end

      {
        scheduler_registered: truthy?(value(scheduler, :registered)),
        scheduler_enabled: truthy?(value(scheduler, :enabled)),
        scheduler_status: value(scheduler, :status),
        scheduler_cron: value(scheduler, :cron),
        scheduler_process_present: truthy?(value(scheduler_process, :present)),
        worker_present: worker_present,
        worker_busy: worker_busy,
        worker_pid: value(worker, :pid),
        worker_label: worker_label,
        queue_size: value(strict, :queue_size).to_i,
        scheduled_jobs: value(strict, :scheduled_jobs).to_i
      }
    end

    def historical_projection_snapshot(sync:)
      raw =
        overview_section(
          :historical_projection
        )

      raw =
        value(
          snapshot,
          :historical_projection
        ) if raw.blank?

      raw =
        value(
          snapshot,
          :tx_outputs_async
        ) if raw.blank?

      raw ||= {}

      outputs_raw =
        value(
          raw,
          :outputs
        )

      spent_sync_raw =
        value(
          raw,
          :spent_sync
        )

      nested_contract =
        outputs_raw.respond_to?(:key?) ||
        spent_sync_raw.respond_to?(:key?)

      unless nested_contract
        return historical_component_snapshot(
          raw: raw,
          sync: sync,
          default_enabled: false
        )
      end

      parent_enabled =
        truthy?(
          value(
            raw,
            :enabled
          )
        )

      outputs =
        historical_component_snapshot(
          raw:
            outputs_raw || {},

          sync: sync,

          default_enabled:
            parent_enabled
        )

      spent_sync =
        historical_component_snapshot(
          raw:
            spent_sync_raw || {},

          sync: sync,

          default_enabled:
            parent_enabled
        )

      pending_count =
        outputs[:pending_count].to_i +
        spent_sync[:pending_count].to_i

      failed_count =
        outputs[:failed_count].to_i +
        spent_sync[:failed_count].to_i

      projection_lag =
        [
          outputs[
            :projection_lag_blocks
          ],

          spent_sync[
            :projection_lag_blocks
          ]
        ]
          .compact
          .map(&:to_i)
          .max

      state =
        aggregate_historical_state(
          outputs[:state],
          spent_sync[:state],
          value(
            raw,
            :status
          )
        )

      label, description =
        historical_projection_copy(
          state: state,
          projection_lag: projection_lag,
          pending_count: pending_count,
          failed_count: failed_count
        )

      {
        enabled:
          parent_enabled ||
          outputs[:enabled] ||
          spent_sync[:enabled],

        status:
          state,

        state:
          state,

        label:
          label,

        description:
          description,

        certified_height:
          sync[
            :processed_height
          ].to_i,

        projection_lag_blocks:
          projection_lag,

        pending_count:
          pending_count,

        failed_count:
          failed_count,

        outputs:
          outputs,

        spent_sync:
          spent_sync
      }
    end

    def historical_component_snapshot(
      raw:,
      sync:,
      default_enabled: false
    )
      raw ||= {}

      enabled_value =
        value(
          raw,
          :enabled
        )

      enabled =
        if enabled_value.nil?
          default_enabled
        else
          truthy?(
            enabled_value
          )
        end

      certified_height =
        sync[
          :processed_height
        ].to_i

      last_synced_height =
        value(
          raw,
          :last_synced_height
        )

      pending_count =
        value(
          raw,
          :pending_count
        ).to_i

      failed_count =
        value(
          raw,
          :failed_count
        ).to_i

      worker =
        value(
          raw,
          :worker
        ) || {}

      worker_present =
        truthy?(
          value(
            worker,
            :present
          )
        )

      worker_busy =
        value(
          worker,
          :busy
        ).to_i

      projection_lag =
        value(
          raw,
          :projection_lag_blocks
        )

      if projection_lag.nil? &&
         last_synced_height.present?
        projection_lag =
          [
            certified_height -
              last_synced_height.to_i,
            0
          ].max
      end

      raw_status =
        value(
          raw,
          :status
        ).to_s

      state =
        if !enabled
          "disabled"

        elsif truthy?(
                value(
                  raw,
                  :migration_pending
                )
              )
          "setup_required"

        elsif value(
                raw,
                :error
              ).present? ||
              raw_status == "unavailable"
          "error"

        elsif failed_count.positive? ||
              raw_status == "failed"
          "failed"

        elsif worker_busy.positive? ||
              raw_status == "processing"
          "processing"

        elsif %w[
                deferred
                behind
              ].include?(
                raw_status
              )
          "deferred"

        elsif pending_count.positive? ||
              projection_lag.to_i.positive? ||
              raw_status == "pending"
          sync[:lag].to_i.positive? ?
            "deferred" :
            "pending"

        elsif raw_status == "synced" ||
              (
                last_synced_height.present? &&
                projection_lag.to_i.zero? &&
                pending_count.zero?
              )
          "synced"

        elsif last_synced_height.nil? &&
              certified_height.positive?
          "initializing"

        else
          "idle"
        end

      label, description =
        historical_projection_copy(
          state: state,
          projection_lag: projection_lag,
          pending_count: pending_count,
          failed_count: failed_count
        )

      {
        enabled:
          enabled,

        status:
          state,

        state:
          state,

        label:
          label,

        description:
          description,

        certified_height:
          certified_height,

        last_synced_height:
          last_synced_height,

        projection_lag_blocks:
          projection_lag,

        pending_count:
          pending_count,

        failed_count:
          failed_count,

        oldest_pending_height:
          value(
            raw,
            :oldest_pending_height
          ),

        oldest_processing_height:
          value(
            raw,
            :oldest_processing_height
          ),

        oldest_processing_age_seconds:
          value(
            raw,
            :oldest_processing_age_seconds
          ),

        next_record_height:
          value(
            raw,
            :next_record_height
          ),

        worker_present:
          worker_present,

        worker_busy:
          worker_busy,

        worker_pid:
          value(
            worker,
            :pid
          ),

        queue_size:
          value(
            raw,
            :queue_size
          ).to_i,

        scheduled_jobs:
          value(
            raw,
            :scheduled_jobs
          ).to_i,

        lock_present:
          truthy?(
            value(
              raw,
              :lock_present
            )
          ),

        historical_budget:
          value(
            raw,
            :historical_budget
          ) || {},

        recovery:
          value(
            raw,
            :recovery
          ) || {},

        error:
          value(
            raw,
            :error
          )
      }
    end

    def aggregate_historical_state(
      outputs_state,
      spent_sync_state,
      parent_state
    )
      states =
        [
          outputs_state,
          spent_sync_state,
          parent_state.to_s.presence
        ]
          .compact
          .map(&:to_s)

      return "failed" if
        states.include?(
          "failed"
        )

      return "error" if
        (
          states &
          %w[
            error
            unavailable
          ]
        ).any?

      return "processing" if
        states.include?(
          "processing"
        )

      return "deferred" if
        states.include?(
          "deferred"
        )

      return "pending" if
        (
          states &
          %w[
            pending
            behind
          ]
        ).any?

      return "synced" if
        states.any? &&
        states.all? do |state|
          %w[
            synced
            idle
            disabled
          ].include?(
            state
          )
        end

      return "disabled" if
        states.any? &&
        states.all? do |state|
          state == "disabled"
        end

      "idle"
    end

    def historical_projection_copy(state:, projection_lag:, pending_count:, failed_count:)
      case state
      when "synced"
        [
          "Synchronisée",
          "La projection historique est alignée avec le dernier bloc certifié. " \
            "Elle reste indépendante de la certification temps réel."
        ]
      when "processing"
        [
          "Mise à jour en cours",
          "Le worker historique projette tx_outputs.spent par petits lots sans bloquer Layer1."
        ]
      when "deferred"
        [
          "En pause — priorité au temps réel",
          "La projection historique reprendra automatiquement lorsque Layer1 sera revenu à zéro retard. " \
            "La certification des blocs reste intacte."
        ]
      when "pending"
        pending_description =
          if projection_lag.nil?
            "#{pending_count} bloc#{'s' unless pending_count == 1} attend#{'ent' unless pending_count == 1} " \
              "encore la mise à jour historique."
          else
            "#{blocks_label(projection_lag.to_i)} de projection et " \
              "#{pending_count} enregistrement#{'s' unless pending_count == 1} attendent encore la mise à jour historique."
          end

        [
          "Rattrapage en arrière-plan",
          pending_description
        ]
      when "failed"
        [
          "Reprise nécessaire",
          "#{failed_count} projection#{'s' unless failed_count == 1} historique#{'s' unless failed_count == 1} " \
            "est en échec. Layer1 reste certifié, mais l’historique doit être repris."
        ]
      when "setup_required"
        [
          "Configuration requise",
          "La migration de suivi de la projection historique n’est pas encore disponible."
        ]
      when "error"
        [
          "Indisponible",
          "L’état de la projection historique ne peut pas être lu actuellement."
        ]
      when "initializing"
        [
          "Initialisation",
          "La projection historique attend son premier checkpoint synchronisé."
        ]
      when "idle"
        [
          "Au repos",
          "Aucune projection historique n’est actuellement en attente."
        ]
      else
        [
          "Non activée",
          "La projection historique asynchrone n’est pas activée dans cet environnement."
        ]
      end
    end

    def current_block_snapshot
      strict = value(snapshot, :strict) || {}
      processing = value(strict, :processing_block)
      return nil unless processing.present?

      started_at = parse_time(value(processing, :processing_started_at))
      heartbeat_at = parse_time(value(processing, :last_heartbeat_at))

      {
        height: value(processing, :height),
        status: value(processing, :status),
        started_at: started_at,
        elapsed_seconds: seconds_since(started_at),
        heartbeat_at: heartbeat_at,
        heartbeat_age_seconds: seconds_since(heartbeat_at)
      }
    end

    def recent_processed_rows
      BlockBufferModel
        .where(status: "processed")
        .where.not(duration_ms: nil)
        .order(height: :desc)
        .limit(RECENT_ROWS_LIMIT)
        .pluck(:height, :duration_ms, :processed_at, :updated_at)
        .map do |height, duration_ms, processed_at, updated_at|
          {
            height: height.to_i,
            duration_ms: duration_ms.to_f,
            processed_at: processed_at || updated_at
          }
        end
    end

    def last_block_details(
      height:,
      fallback:
    )
      base =
        fallback ||
        {}

      return base unless
        height.present?

      record =
        BlockBufferModel
          .where(
            height: height,
            status: "processed"
          )
          .first

      return base.merge(
        height: height.to_i
      ) unless record

      raw_metrics =
        if record.respond_to?(
             :strict_metrics
           )
          record.strict_metrics
        else
          record.attributes[
            "strict_metrics"
          ]
        end

      metrics =
        normalized_hash(
          raw_metrics
        )

      stage_timings =
        normalized_hash(
          value(
            metrics,
            :stage_timings
          )
        )

      base.merge(
        height:
          record.height.to_i,

        block_hash:
          record.block_hash,

        previous_hash:
          record.previous_hash,

        block_time:
          record.block_time,

        processed_at:
          record.processed_at ||
          record.updated_at,

        tx_count:
          record.tx_count,

        size_bytes:
          record.size_bytes,

        attempts:
          record.attempts,

        duration_ms:
          record.duration_ms ||
          value(
            metrics,
            :duration_ms
          ),

        rpc_duration_ms:
          record.rpc_duration_ms ||
          value(
            metrics,
            :rpc_duration_ms
          ),

        parse_duration_ms:
          record.parse_duration_ms ||
          value(
            metrics,
            :parse_duration_ms
          ),

        flush_duration_ms:
          record.flush_duration_ms ||
          value(
            metrics,
            :flush_duration_ms
          ),

        metrics:
          metrics,

        stage_timings:
          stage_timings,

        flush_metrics:
          normalized_hash(
            value(
              metrics,
              :flush_metrics
            )
          ),

        strict_outputs_count:
          value(
            metrics,
            :strict_outputs
          ),

        cluster_inputs_count:
          value(
            metrics,
            :cluster_inputs
          ),

        outputs_audit_ok:
          value(
            metrics,
            :outputs_audit_ok
          ),

        inputs_audit_ok:
          value(
            metrics,
            :inputs_audit_ok
          ),

        utxo_audit_ok:
          value(
            metrics,
            :utxo_audit_ok
          ),

        outputs_audit_status:
          value(
            metrics,
            :outputs_audit_status
          ),

        node_inputs_count:
          value(
            metrics,
            :node_inputs_count
          ),

        db_inputs_count:
          value(
            metrics,
            :db_inputs_count
          ),

        node_inputs_value_btc:
          value(
            metrics,
            :node_inputs_value_btc
          ),

        db_inputs_value_btc:
          value(
            metrics,
            :db_inputs_value_btc
          ),

        expected_live_outputs_count:
          value(
            metrics,
            :expected_live_outputs_count
          ),

        actual_live_utxos_count:
          value(
            metrics,
            :actual_live_utxos_count
          ),

        expected_live_value_btc:
          value(
            metrics,
            :expected_live_value_btc
          ),

        actual_live_value_btc:
          value(
            metrics,
            :actual_live_value_btc
          ),

        orphan_utxos_count:
          value(
            metrics,
            :orphan_utxos_count
          ),

        spent_rows_still_in_utxo:
          value(
            metrics,
            :spent_rows_still_in_utxo
          ),

        processor_mode:
          value(
            metrics,
            :processor_mode
          ),

        processor_transactions:
          value(
            metrics,
            :processor_transactions
          ),

        processor_outputs:
          value(
            metrics,
            :processor_outputs
          ),

        processor_spent_outputs:
          value(
            metrics,
            :processor_spent_outputs
          ),

        prevout_found:
          value(
            metrics,
            :prevout_found
          ),

        prevout_missing:
          value(
            metrics,
            :prevout_missing
          ),

        reconcile_spent_outputs:
          value(
            metrics,
            :reconcile_spent_outputs
          ) || {},

        tx_output_projection_status:
          value(
            metrics,
            :tx_output_projection_status
          ),

        tx_outputs_sync_status:
          value(
            metrics,
            :tx_outputs_sync_status
          )
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[layer1_dashboard_snapshot] " \
        "last_block_details_error " \
        "#{error.class}: #{error.message}"
      )

      base.merge(
        height: height.to_i
      )
    end

    def build_recent_blocks(rows)
      rows
        .first(RECENT_BLOCKS_LIMIT)
        .map do |row|
          {
            height: row[:height],
            duration_ms: row[:duration_ms],
            duration_minutes: row[:duration_ms] / 60_000.0,
            processed_at: row[:processed_at]
          }
        end
    end

    def average_duration(rows)
      durations = rows.map { |row| row[:duration_ms].to_f }
      return nil if durations.empty?

      durations.sum / durations.size
    end

    def performance_snapshot(
      recent_blocks:,
      last_height:,
      last_duration_ms:,
      average_duration_ms:,
      average_blocks_count:
    )
      ratio =
        if last_duration_ms && average_duration_ms.to_f.positive?
          last_duration_ms.to_f / average_duration_ms.to_f
        end

      deviation_pct =
        if ratio
          ((ratio - 1.0) * 100).round
        end

      state =
        if last_duration_ms.nil? || average_duration_ms.nil?
          "unknown"
        elsif ratio >= 1.40 && last_duration_ms >= 120_000
          "slower"
        elsif ratio >= 1.20 && last_duration_ms >= 120_000
          "slightly_slower"
        elsif ratio <= 0.75
          "faster"
        else
          "normal"
        end

      block_label =
        if last_height.present?
          "du bloc #{formatted_integer(last_height)}"
        else
          "du dernier bloc"
        end

      baseline_label =
        if average_blocks_count == 1
          "du bloc précédent"
        else
          "des #{average_blocks_count} blocs précédents"
        end

      label, description =
        case state
        when "slower"
          [
            "Plus lente que la moyenne récente",
            "La certification #{block_label} a demandé davantage de temps que la moyenne #{baseline_label}. " \
              "Elle est terminée et ce signal ne dégrade pas à lui seul la santé globale."
          ]
        when "slightly_slower"
          [
            "Légèrement au-dessus de la moyenne",
            "La certification #{block_label} a demandé un peu plus de temps que la moyenne #{baseline_label}, " \
              "sans sortir de la plage de fonctionnement habituelle."
          ]
        when "faster"
          [
            "Plus rapide que la moyenne",
            "La certification #{block_label} a été plus rapide que la moyenne #{baseline_label}."
          ]
        when "normal"
          [
            "Dans la moyenne récente",
            "La durée de certification #{block_label} reste cohérente avec la moyenne #{baseline_label}."
          ]
        else
          [
            "Mesure indisponible",
            "Aucune durée exploitable n’est encore disponible pour établir une tendance."
          ]
        end

      {
        state: state,
        label: label,
        description: description,
        last_duration_ms: last_duration_ms,
        average_duration_ms: average_duration_ms,
        average_blocks_count: average_blocks_count,
        ratio: ratio,
        deviation_pct: deviation_pct,
        recent_blocks: recent_blocks,

        last_block:
          last_block_details(
            height: last_height,
            fallback: recent_blocks.first
          ),

        max_recent_duration_ms:
          recent_blocks.map { |row| row[:duration_ms] }.max.to_f
      }
    end

    def proof_snapshot
      last_audit =
        if defined?(Layer1AuditRun)
          Layer1AuditRun.order(created_at: :desc).first
        end

      last_audits =
        if defined?(Layer1AuditRun)
          Layer1AuditRun.order(created_at: :desc).limit(10)
        else
          []
        end

      checks = last_audit&.checks || {}
      total = checks.size

      passed =
        checks.count do |_name, result|
          result_value =
            if result.respond_to?(:key?) && result.key?("passed")
              result["passed"]
            elsif result.respond_to?(:key?) && result.key?(:passed)
              result[:passed]
            end

          truthy?(result_value)
        end

      compliance =
        total.zero? ? nil : ((passed.to_f / total) * 100).round

      {
        last_audit: last_audit,
        last_audits: last_audits,
        total_checks: total,
        passed_checks: passed,
        compliance: compliance,
        conformant: compliance == 100
      }
    end

    def blocks_label(count)
      "#{count} bloc#{'s' unless count == 1}"
    end

    def formatted_integer(number)
      number.to_i.to_s.reverse.scan(/.{1,3}/).join(" ").reverse
    end

    def overview_section(key)
      return {} unless
        raw_source ==
          "layer1_overview_snapshot"

      section =
        raw_value(
          @raw_snapshot,
          key
        )

      return {} unless
        section.is_a?(
          Hash
        )

      if section.respond_to?(
           :with_indifferent_access
         )
        section.with_indifferent_access
      else
        section
      end
    end

    def overview_value(key)
      return nil unless
        raw_source ==
          "layer1_overview_snapshot"

      raw_value(
        @raw_snapshot,
        key
      )
    end

    def normalized_hash(raw)
      result =
        case raw
        when Hash
          raw
        when String
          JSON.parse(raw)
        else
          {}
        end

      if result.respond_to?(
           :with_indifferent_access
         )
        result.with_indifferent_access
      else
        result
      end
    rescue JSON::ParserError,
           TypeError
      {}.with_indifferent_access
    end

    def value(hash, key)
      return nil unless hash.respond_to?(:key?)

      return hash[key] if hash.key?(key)

      string_key = key.to_s
      return hash[string_key] if hash.key?(string_key)

      nil
    end

    def truthy?(value)
      value == true || value.to_s == "true" || value.to_s == "1"
    end

    def parse_time(value)
      return value if value.respond_to?(:in_time_zone)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def seconds_since(time)
      return nil unless time

      [(Time.current - time).to_i, 0].max
    end
  end
end
