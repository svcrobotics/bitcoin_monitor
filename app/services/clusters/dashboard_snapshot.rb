# frozen_string_literal: true

module Clusters
  class DashboardSnapshot
    RECENT_BLOCKS_LIMIT = 5
    AVERAGE_BLOCKS_LIMIT = 10
    PERFORMANCE_HISTORY_LIMIT = AVERAGE_BLOCKS_LIMIT + 1
    LAYER1_SAFETY_LAG = 3

    def self.call(
      snapshot:,
      decision: nil
    )
      new(
        snapshot: snapshot,
        decision: decision
      ).call
    end

    def initialize(
      snapshot:,
      decision: nil
    )
      @snapshot = snapshot || {}
      @decision = decision || {}
    end

    def call
      sync = sync_snapshot
      automation = automation_snapshot
      pipeline = pipeline_snapshot(sync: sync, automation: automation)
      proof = proof_snapshot(sync)
      certification_history = certification_history_snapshot
      recent_rows = recent_processed_rows
      recent_blocks = build_recent_blocks(recent_rows)
      comparison_rows = recent_rows.drop(1).first(AVERAGE_BLOCKS_LIMIT)
      average_duration_ms = average_duration(comparison_rows)
      last_duration_ms = recent_rows.first&.fetch(:duration_ms)

      {
        status: normalized_status,
        display_status: display_status(
          sync: sync,
          automation: automation,
          pipeline: pipeline,
          proof: proof
        ),
        status_label: status_label(
          sync: sync,
          automation: automation,
          pipeline: pipeline,
          proof: proof
        ),
        status_summary: status_summary(
          sync: sync,
          automation: automation,
          pipeline: pipeline,
          proof: proof
        ),
        sync: sync,
        pipeline: pipeline,
        automation: automation,
        current_block: current_block_snapshot(
          sync: sync,
          automation: automation
        ),
        performance: performance_snapshot(
          sync: sync,
          recent_blocks: recent_blocks,
          last_duration_ms: last_duration_ms,
          average_duration_ms: average_duration_ms,
          average_sample_count: comparison_rows.size
        ),
        proof: proof,
        certification_history: certification_history,
        coverage: coverage_snapshot(sync),
        actor_profile: actor_profile_snapshot(sync),
        counts: value(snapshot, :counts) || {},
        activity: value(snapshot, :activity) || {},
        issues: Array(value(snapshot, :issues)),
        legacy: value(snapshot, :legacy) || {}
      }
    end

    private

    attr_reader :snapshot,
                :decision

    def layer1_safety_lag
      return LAYER1_SAFETY_LAG unless
        ENV["TANSA_PIPELINE_MODE"].to_s ==
          "development_backfill"

      [
        Integer(
          ENV.fetch(
            "TANSA_BACKFILL_MAX_LAYER1_LAG",
            "20"
          )
        ),
        0
      ].max
    rescue ArgumentError, TypeError
      LAYER1_SAFETY_LAG
    end

    def normalized_status
      value(snapshot, :status).to_s.presence || "unknown"
    end

    def display_status(sync:, automation:, pipeline:, proof:)
      issues = Array(value(snapshot, :issues))

      return "critical" if issues.any? && !automation[:active]
      return "warning" if proof[:applicable] && !proof[:conformant]
      return "healthy" if sync[:cluster_lag].zero? && proof[:conformant]

      if automation[:active] ||
         pipeline[:state] == "queued" ||
         pipeline[:state] == "waiting_for_layer1"
        "syncing"
      else
        normalized_status
      end
    end

    def sync_snapshot
      sync = value(snapshot, :sync) || {}

      layer1_tip =
        value(sync, :layer1_tip) ||
        value(sync, :best_height)

      cluster_tip =
        value(sync, :cluster_tip) ||
        value(sync, :scanner_cursor)

      layer1_tip = layer1_tip.to_i
      cluster_tip = cluster_tip.to_i

      bitcoin_core_height =
        value(sync, :bitcoin_core_height).to_i

      layer1_lag =
        if bitcoin_core_height.positive?
          [bitcoin_core_height - layer1_tip, 0].max
        else
          0
        end

      cluster_lag =
        value(sync, :scanner_lag)

      cluster_lag =
        [layer1_tip - cluster_tip, 0].max if cluster_lag.nil?

      {
        bitcoin_core_height: bitcoin_core_height,
        layer1_tip: layer1_tip,
        layer1_status: value(sync, :layer1_status).to_s,
        layer1_lag: layer1_lag,
        cluster_tip: cluster_tip,
        cluster_lag: cluster_lag.to_i,
        cluster_input_max_height: value(sync, :cluster_input_max_height),
        cluster_input_max_spent: value(sync, :cluster_input_max_spent)
      }
    end

    def automation_snapshot
      automation = value(snapshot, :automation) || {}
      process = value(automation, :process) || {}

      process_present = truthy?(value(process, :present))
      process_busy = value(process, :busy).to_i
      active_workers = value(automation, :active_workers).to_i
      queue_size = value(automation, :queue_size).to_i
      scheduled_jobs = value(automation, :scheduled_jobs).to_i
      retry_jobs = value(automation, :retry_jobs).to_i
      dead_jobs = value(automation, :dead_jobs).to_i

      active =
        process_busy.positive? ||
        active_workers.positive?

      worker_label =
        if active
          "En traitement"
        elsif process_present
          "Disponible"
        else
          "Absent"
        end

      {
        queue_name: value(automation, :queue_name).presence || "cluster_strict",
        process_present: process_present,
        process_busy: process_busy,
        process_pid: value(process, :pid),
        process_concurrency: value(process, :concurrency).to_i,
        active_workers: active_workers,
        active: active,
        worker_label: worker_label,
        queue_size: queue_size,
        scheduled_jobs: scheduled_jobs,
        retry_jobs: retry_jobs,
        dead_jobs: dead_jobs,
        automation_ok: truthy?(value(automation, :automation_ok))
      }
    end

    def pipeline_snapshot(sync:, automation:)
      if controller_decision_available?
        return controller_pipeline_snapshot(
          sync: sync,
          automation: automation
        )
      end

      issues = Array(value(snapshot, :issues))

      state =
        if issues.any? && !automation[:active]
          "blocked"
        elsif sync[:layer1_lag] > layer1_safety_lag
          "waiting_for_layer1"
        elsif sync[:cluster_lag].zero? && !automation[:active]
          "idle_synced"
        elsif automation[:active]
          "active"
        elsif automation[:queue_size].positive? ||
              automation[:scheduled_jobs].positive?
          "queued"
        elsif sync[:cluster_lag].positive?
          "waiting_for_job"
        else
          "unknown"
        end

      label, description =
        case state
        when "active"
          [
            "Rattrapage en cours",
            "Cluster traite actuellement les blocs déjà certifiés par Layer1. " \
              "Le retard est visible, mais le pipeline progresse automatiquement."
          ]
        when "waiting_for_layer1"
          [
            "En attente de Layer1",
            "La barrière de sécurité suspend Cluster tant que Layer1 présente plus de " \
              "#{layer1_safety_lag} blocs de retard."
          ]
        when "idle_synced"
          [
            "À jour — en attente du prochain bloc",
            "Cluster est synchronisé avec Layer1. L’absence de worker actif est normale."
          ]
        when "queued"
          [
            "Travail planifié",
            "Un passage Cluster est en queue ou planifié et sera pris en charge automatiquement."
          ]
        when "waiting_for_job"
          [
            "Déclenchement attendu",
            "Cluster est en retard mais aucun traitement actif n’est actuellement observé."
          ]
        when "blocked"
          [
            "Intervention requise",
            "L’automatisation Cluster signale un problème qui empêche une progression normale."
          ]
        else
          [
            "État indéterminé",
            "Les informations disponibles ne permettent pas d’établir l’état du pipeline."
          ]
        end

      {
        state: state,
        label: label,
        description: description
      }
    end

    def controller_decision_available?
      decision.respond_to?(:key?) &&
        (
          decision.key?(:allowed) ||
          decision.key?("allowed")
        )
    end

    def controller_pipeline_snapshot(
      sync:,
      automation:
    )
      allowed =
        truthy?(
          value(
            decision,
            :allowed
          )
        )

      controller_state =
        value(
          decision,
          :state
        ).to_s

      reason =
        value(
          decision,
          :reason
        ).to_s

      failed_constraints =
        Array(
          value(
            decision,
            :failed_constraints
          )
        ).map(&:to_s)

      state =
        if automation[:active] ||
           controller_state == "processing"
          "active"

        elsif allowed &&
              sync[:cluster_lag].zero?
          "idle_synced"

        elsif allowed &&
              (
                automation[:queue_size].positive? ||
                automation[:scheduled_jobs].positive?
              )
          "queued"

        elsif allowed
          "waiting_for_job"

        elsif reason ==
              "layer1_realtime_priority"
          "waiting_for_layer1"

        else
          "blocked"
        end

      label, description =
        case state
        when "active"
          [
            "Rattrapage en cours",
            "Cluster traite actuellement les blocs certifiés disponibles depuis Layer1."
          ]

        when "idle_synced"
          [
            "À jour — en attente du prochain bloc",
            "Cluster est synchronisé avec le checkpoint Layer1 disponible."
          ]

        when "queued"
          [
            "Travail planifié",
            "Un passage Cluster est en queue ou déjà planifié par le scheduler strict."
          ]

        when "waiting_for_job"
          [
            "Rattrapage en attente de déclenchement",
            "Cluster a #{sync[:cluster_lag]} bloc(s) à rattraper. "               "Le contrôleur autorise son exécution et le worker attend le scheduler strict."
          ]

        when "waiting_for_layer1"
          [
            "En attente de Layer1",
            layer1_waiting_description(
              failed_constraints
            )
          ]

        else
          [
            "Pipeline Cluster bloqué",
            "Le contrôleur refuse actuellement Cluster : "               "#{reason.presence || 'raison non disponible'}."
          ]
        end

      {
        state: state,
        label: label,
        description: description,
        controller_allowed: allowed,
        controller_state: controller_state,
        controller_reason: reason.presence,
        failed_constraints: failed_constraints
      }
    end

    def layer1_waiting_description(
      failed_constraints
    )
      if failed_constraints.include?(
           "layer1_not_processing"
         ) ||
         failed_constraints.include?(
           "layer1_strict_worker_idle"
         )
        return(
          "Layer1 traite actuellement son propre retard. "           "Cluster reprendra dès que Layer1 aura libéré le pipeline strict."
        )
      end

      if failed_constraints.include?(
           "strict_io_not_layer1"
         )
        return(
          "Layer1 détient actuellement le verrou d’écriture strict. "           "Cluster attend sa libération avant de reprendre."
        )
      end

      "Cluster attend que Layer1 libère les ressources strictes nécessaires."
    end

    def status_label(sync:, automation:, pipeline:, proof:)
      issues = Array(value(snapshot, :issues))

      return "Intervention requise" if issues.any? && !automation[:active]
      return "Synchronisé sous surveillance" if proof[:applicable] && !proof[:conformant]
      return "Synchronisé et conforme" if sync[:cluster_lag].zero? && proof[:conformant]
      return "Audit Cluster en attente" if sync[:cluster_lag].zero? && proof[:pending]
      return "En attente de Layer1" if pipeline[:state] == "waiting_for_layer1"

      if automation[:active]
        if sync[:cluster_lag] > 20
          "Rattrapage important en cours"
        else
          "Rattrapage en cours"
        end
      elsif pipeline[:state] == "queued"
        "Rattrapage planifié"
      elsif pipeline[:state] == "waiting_for_job" &&
            automation[:process_present]
        "Rattrapage en attente de déclenchement"
      else
        "Retard Cluster à surveiller"
      end
    end

    def status_summary(sync:, automation:, pipeline:, proof:)
      if sync[:cluster_lag].zero? && proof[:conformant]
        "Cluster a certifié le dernier bloc disponible depuis Layer1. " \
          "Sur la fenêtre auditée, #{proof[:processed_candidate_transactions]} / " \
          "#{proof[:candidate_transactions]} transactions multi-adresses ont été traitées " \
          "et les #{proof[:total_checks]} contrôles stricts sont conformes."
      elsif proof[:applicable] && !proof[:conformant]
        "Cluster est synchronisé avec Layer1, mais l’audit strict signale " \
          "#{proof[:anomalies]} anomalie(s) sur le périmètre multi-adresses certifié."
      elsif sync[:cluster_lag].zero? && proof[:pending]
        "Cluster est synchronisé avec Layer1, mais la preuve récente attend encore un checkpoint strict exploitable."
      elsif pipeline[:state] == "waiting_for_layer1"
        pipeline[:description]
      elsif automation[:active]
        "Cluster transforme les entrées certifiées de Layer1 en groupes d’adresses liés. " \
          "Il reste #{sync[:cluster_lag]} bloc(s) à rattraper."
      elsif pipeline[:state] == "queued"
        "Cluster a #{sync[:cluster_lag]} bloc(s) à rattraper. Le prochain passage est déjà " \
          "planifié et sera pris en charge automatiquement."
      elsif pipeline[:state] == "waiting_for_job" &&
            automation[:process_present]
        "Cluster a #{sync[:cluster_lag]} bloc(s) à rattraper. Le worker est disponible " \
          "et attend le prochain déclenchement du scheduler strict."
      else
        "Cluster accuse #{sync[:cluster_lag]} bloc(s) de retard et aucun worker disponible " \
          "n’est actuellement observé."
      end
    end

    def current_block_snapshot(sync:, automation:)
      return nil unless sync[:cluster_lag].positive?
      return nil unless automation[:active]

      height = sync[:cluster_tip] + 1
      scope = ClusterInput.where(spent_block_height: height)

      candidate_txids =
        scope
          .where.not(address: [nil, ""])
          .group(:spent_txid)
          .having("COUNT(DISTINCT address) >= 2")
          .count
          .keys

      processed_txids =
        if candidate_txids.empty?
          0
        else
          scope
            .where(spent_txid: candidate_txids)
            .where.not(cluster_processed_at: nil)
            .distinct
            .count(:spent_txid)
        end

      progress =
        if candidate_txids.empty?
          nil
        else
          ((processed_txids.to_f / candidate_txids.size) * 100).round(1)
        end

      last_progress_at =
        scope
          .where.not(cluster_processed_at: nil)
          .maximum(:cluster_processed_at)

      {
        height: height,
        candidate_transactions: candidate_txids.size,
        processed_transactions: processed_txids,
        progress: progress,
        last_progress_at: last_progress_at,
        progress_age_seconds:
          last_progress_at ? [(Time.current - last_progress_at).to_i, 0].max : nil
      }
    rescue StandardError => error
      {
        height: height,
        error: "#{error.class}: #{error.message}"
      }
    end

    def certification_history_snapshot
      return empty_certification_history unless defined?(ClusterProcessedBlock)

      scope = ClusterProcessedBlock.where(status: "processed")
      first_height = scope.minimum(:height)&.to_i
      last_height = scope.maximum(:height)&.to_i

      return empty_certification_history unless first_height && last_height

      expected_blocks = last_height - first_height + 1
      certified_blocks =
        scope
          .where(height: first_height..last_height)
          .distinct
          .count(:height)
          .to_i
      missing_blocks = [expected_blocks - certified_blocks, 0].max

      {
        available: true,
        first_height: first_height,
        last_height: last_height,
        certified_blocks: certified_blocks,
        expected_blocks: expected_blocks,
        missing_blocks: missing_blocks,
        continuous: missing_blocks.zero?,
        error: nil
      }
    rescue StandardError => error
      empty_certification_history.merge(error: "#{error.class}: #{error.message}")
    end

    def empty_certification_history
      {
        available: false,
        first_height: nil,
        last_height: nil,
        certified_blocks: 0,
        expected_blocks: 0,
        missing_blocks: 0,
        continuous: false,
        error: nil
      }
    end

    def recent_processed_rows
      return [] unless defined?(ClusterProcessedBlock)

      columns = ClusterProcessedBlock.column_names
      records =
        ClusterProcessedBlock
          .where(status: "processed")
          .order(height: :desc)
          .limit(PERFORMANCE_HISTORY_LIMIT)
          .to_a

      records.filter_map do |record|
        duration_ms = duration_for(record, columns)
        next unless duration_ms&.positive?

        {
          height:
            record.height.to_i,

          duration_ms:
            duration_ms,

          processed_at:
            timestamp_for(
              record,
              columns
            ),

          stage_timings:
            record_hash(
              record,
              columns,
              "stage_timings"
            ),

          scan_result:
            record_hash(
              record,
              columns,
              "scan_result"
            ),

          cleanup_result:
            record_hash(
              record,
              columns,
              "cleanup_result"
            ),

          audit_result:
            record_hash(
              record,
              columns,
              "audit_result"
            )
        }
      end
    rescue StandardError
      []
    end

    def duration_for(record, columns)
      if columns.include?("duration_ms")
        duration = record.read_attribute("duration_ms").to_f
        return duration if duration.positive?
      end

      started_at =
        if columns.include?("processing_started_at")
          record.read_attribute("processing_started_at")
        elsif columns.include?("started_at")
          record.read_attribute("started_at")
        else
          record.created_at
        end

      finished_at =
        if columns.include?("processed_at")
          record.read_attribute("processed_at")
        elsif columns.include?("finished_at")
          record.read_attribute("finished_at")
        else
          record.updated_at
        end

      return nil unless started_at && finished_at

      duration = (finished_at - started_at) * 1000
      duration.positive? ? duration : nil
    end

    def record_hash(
      record,
      columns,
      column
    )
      return {} unless columns.include?(
        column
      )

      value =
        record.read_attribute(
          column
        )

      case value
      when Hash
        value.deep_symbolize_keys

      when String
        decoded =
          ActiveSupport::JSON.decode(
            value
          )

        decoded.respond_to?(
          :deep_symbolize_keys
        ) ?
          decoded.deep_symbolize_keys :
          {}

      else
        {}
      end
    rescue StandardError
      {}
    end

    def timestamp_for(record, columns)
      if columns.include?("processed_at")
        record.read_attribute("processed_at") || record.updated_at
      elsif columns.include?("finished_at")
        record.read_attribute("finished_at") || record.updated_at
      else
        record.updated_at
      end
    end

    def build_recent_blocks(rows)
      rows
        .first(RECENT_BLOCKS_LIMIT)
        .map do |row|
          {
            height:
              row[:height],

            duration_ms:
              row[:duration_ms],

            duration_minutes:
              row[:duration_ms] /
              60_000.0,

            processed_at:
              row[:processed_at],

            stage_timings:
              row[:stage_timings] || {},

            scan_result:
              row[:scan_result] || {},

            cleanup_result:
              row[:cleanup_result] || {},

            audit_result:
              row[:audit_result] || {}
          }
        end
    end

    def average_duration(rows)
      durations = rows.map { |row| row[:duration_ms].to_f }
      return nil if durations.empty?

      durations.sum / durations.size
    end

    def performance_snapshot(
      sync:,
      recent_blocks:,
      last_duration_ms:,
      average_duration_ms:,
      average_sample_count:
    )
      ratio =
        if last_duration_ms && average_duration_ms.to_f.positive?
          last_duration_ms.to_f / average_duration_ms.to_f
        end

      deviation_pct =
        ratio ? ((ratio - 1.0) * 100).round : nil

      throughput_per_hour =
        if average_duration_ms.to_f.positive?
          (3_600_000.0 / average_duration_ms).round(1)
        end

      eta_seconds =
        if average_duration_ms.to_f.positive? && sync[:cluster_lag].positive?
          (average_duration_ms * sync[:cluster_lag] / 1000.0).round
        end

      state =
        if last_duration_ms.nil? || average_duration_ms.nil?
          "unknown"
        elsif ratio >= 1.40 && last_duration_ms >= 60_000
          "slower"
        elsif ratio <= 0.75
          "faster"
        else
          "normal"
        end

      label, description =
        case state
        when "slower"
          [
            "Plus lente que la moyenne récente",
            "Le dernier bloc Cluster a demandé davantage de temps que la moyenne des traitements récents."
          ]
        when "faster"
          [
            "Plus rapide que la moyenne récente",
            "Le dernier bloc Cluster a été traité plus rapidement que la moyenne récente."
          ]
        when "normal"
          [
            "Dans la moyenne récente",
            "La durée du dernier bloc reste cohérente avec les traitements récents."
          ]
        else
          description =
            if last_duration_ms
              "La première durée Cluster est enregistrée. La comparaison apparaîtra après le prochain bloc mesuré."
            else
              "Les prochaines certifications Cluster enregistreront automatiquement leur durée de traitement."
            end

          ["Mesure en cours", description]
        end

      {
        state: state,
        label: label,
        description: description,
        last_duration_ms: last_duration_ms,
        average_duration_ms: average_duration_ms,
        average_sample_count: average_sample_count.to_i,
        deviation_pct: deviation_pct,
        throughput_per_hour: throughput_per_hour,
        eta_seconds: eta_seconds,
        recent_blocks: recent_blocks,
        last_block: recent_blocks.first,
        max_recent_duration_ms:
          recent_blocks.map { |row| row[:duration_ms] }.max.to_f
      }
    end

    def coverage_snapshot(sync)
      coverage = value(snapshot, :coverage) || {}
      applicable = sync[:cluster_lag].zero?

      {
        applicable: applicable,
        pending: !applicable,
        reason:
          applicable ? nil : "Cluster doit finir son rattrapage avant que la couverture des derniers blocs Layer1 soit comparable.",
        window_blocks: value(coverage, :window_blocks).to_i,
        total_inputs: value(coverage, :total_inputs).to_i,
        total_btc: decimal_to_float(value(coverage, :total_btc)),
        clustered_btc: decimal_to_float(value(coverage, :clustered_btc)),
        nil_cluster_btc: decimal_to_float(value(coverage, :nil_cluster_btc)),
        btc_coverage_pct: value(coverage, :btc_coverage_pct).to_f,
        nil_cluster_inputs: value(coverage, :nil_cluster_inputs).to_i,
        addresses_total: value(coverage, :addresses_total).to_i,
        addresses_nil_cluster: value(coverage, :addresses_nil_cluster).to_i,
        total_transactions: value(coverage, :total_transactions).to_i,
        distinct_addresses: value(coverage, :distinct_addresses).to_i,
        strict_inputs: value(coverage, :strict_inputs).to_i,
        strict_transactions: value(coverage, :strict_transactions).to_i,
        strict_distinct_addresses: value(coverage, :strict_distinct_addresses).to_i,
        outside_strict_inputs: value(coverage, :outside_strict_inputs).to_i,
        missing_address_rows: value(coverage, :missing_address_rows).to_i,
        missing_distinct_addresses: value(coverage, :missing_distinct_addresses).to_i,
        unclustered_rows: value(coverage, :unclustered_rows).to_i,
        unclustered_distinct_addresses: value(coverage, :unclustered_distinct_addresses).to_i,
        invalid_cluster_refs: value(coverage, :invalid_cluster_refs).to_i,
        error: value(coverage, :error)
      }
    end

    def proof_snapshot(sync)
      audit = value(snapshot, :audit) || {}
      counts = value(audit, :counts) || {}
      integrity = value(audit, :integrity) || {}
      heights = Array(value(audit, :heights))

      checks = {
        missing_addresses: value(integrity, :missing_addresses).to_i,
        unclustered_addresses: value(integrity, :unclustered_addresses).to_i,
        invalid_cluster_refs: value(integrity, :invalid_cluster_refs).to_i,
        recent_empty_clusters: value(integrity, :recent_empty_clusters).to_i
      }

      audit_last_height = heights.map(&:to_i).max
      applicable =
        audit_last_height.present? &&
        audit_last_height <= sync[:cluster_tip]

      missing_processed_candidate_transactions =
        value(counts, :missing_processed_candidate_transactions).to_i

      audit_available =
        heights.any?

      visible_checks =
        audit_available ? checks : {}

      passed =
        visible_checks.count do |_name, count|
          count.zero?
        end

      total =
        visible_checks.size

      raw_compliance =
        if total.zero?
          nil
        else
          (
            (
              passed.to_f /
              total
            ) * 100
          ).round
        end

      anomalies =
        if audit_available
          visible_checks.values.sum +
            missing_processed_candidate_transactions
        else
          0
        end

      audit_status =
        value(
          audit,
          :status
        ).to_s.presence ||
        "unknown"

      {
        applicable: applicable,
        pending: !applicable,
        reason:
          applicable ? nil : "Les blocs audités ne sont pas encore tous arrivés au checkpoint Cluster.",
        status: audit_status,
        generated_at: value(audit, :generated_at),
        heights: heights,
        first_height: heights.first,
        last_height: heights.last,
        cluster_inputs: value(counts, :cluster_inputs).to_i,
        distinct_input_addresses:
          value(counts, :distinct_input_addresses).to_i,
        candidate_transactions: value(counts, :candidate_transactions).to_i,
        processed_candidate_transactions:
          value(counts, :processed_candidate_transactions).to_i,
        missing_processed_candidate_transactions:
          missing_processed_candidate_transactions,
        total_cluster_inputs: value(counts, :total_cluster_inputs).to_i,
        total_transactions: value(counts, :total_transactions).to_i,
        total_distinct_addresses: value(counts, :total_distinct_addresses).to_i,
        touched_clusters: value(counts, :touched_clusters).to_i,
        checks: visible_checks,
        passed_checks: passed,
        total_checks: total,
        compliance: applicable ? raw_compliance : nil,
        anomalies: anomalies,
        conformant:
          applicable &&
          audit_status == "healthy" &&
          anomalies.zero? &&
          total.positive?,
        last_cluster_processed_at:
          value(value(audit, :activity) || {}, :last_cluster_processed_at),
        error: value(audit, :error)
      }
    end

    def actor_profile_snapshot(sync)
      return empty_actor_profile_snapshot unless defined?(ActorProfile)

      columns = ActorProfile.column_names

      height_column =
        %w[
          last_computed_height
          computed_height
          last_cluster_height
          last_processed_height
        ].find { |column| columns.include?(column) }

      profile_tip =
        height_column ? ActorProfile.maximum(height_column).to_i : nil

      {
        count: ActorProfile.count,
        tip: profile_tip,
        lag:
          profile_tip.nil? ? nil : [sync[:cluster_tip] - profile_tip, 0].max,
        last_updated_at: ActorProfile.maximum(:updated_at),
        ready: sync[:cluster_lag].zero?
      }
    rescue StandardError
      empty_actor_profile_snapshot
    end

    def empty_actor_profile_snapshot
      {
        count: 0,
        tip: nil,
        lag: nil,
        last_updated_at: nil,
        ready: false
      }
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

    def decimal_to_float(value)
      value.respond_to?(:to_f) ? value.to_f : 0.0
    end
  end
end
