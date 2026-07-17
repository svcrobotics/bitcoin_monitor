# frozen_string_literal: true

require "bigdecimal"

module Clusters
  class StrictHealthSnapshot
    STRICT_QUEUE = "cluster_strict"
    RECENT_BLOCKS = 10

    DEVELOPMENT_BACKFILL_MODE =
      "development_backfill"

    BACKFILL_MAX_CLUSTER_GLOBAL_LAG_ENV =
      "TANSA_BACKFILL_MAX_CLUSTER_GLOBAL_LAG"

    DEFAULT_BACKFILL_MAX_CLUSTER_GLOBAL_LAG =
      30

    def self.call
      new.call
    end

    def call
      require "sidekiq/api"

      layer1 = Layer1::OperationalSnapshot.call
      layer1_tip = layer1[:processed_height].to_i

      cluster_tip = strict_cluster_tip
      cluster_lag = [layer1_tip - cluster_tip, 0].max

      bitcoin_core_height =
        layer1[:bitcoin_core_height].to_i

      cluster_global_lag =
        if bitcoin_core_height.positive?
          [
            bitcoin_core_height -
              cluster_tip,
            0
          ].max
        else
          cluster_lag
        end

      process = strict_process
      queue_size = Sidekiq::Queue.new(STRICT_QUEUE).size
      scheduled_jobs = scheduled_count
      active_workers = strict_workers
      retry_jobs = retry_count
      dead_jobs = dead_count

      # Le scheduler strict central décide quand déclencher Cluster.
      # Un processus Sidekiq Cluster présent suffit donc à confirmer
      # que l’automatisation est disponible, même entre deux jobs.
      automation_ok =
        automation_available?(
          process: process
        )

      issues = []
      issues << "cluster_strict_worker_missing" unless process[:present]
      issues << "cluster_strict_automation_missing" unless automation_ok
      issues << "cluster_tip_above_layer1" if cluster_tip > layer1_tip
      issues << "cluster_retry_jobs_present" if retry_jobs.positive?
      issues << "cluster_dead_jobs_present" if dead_jobs.positive?

      recent_heights = strict_recent_heights
      recent_scope = ClusterInput.where(spent_block_height: recent_heights)

      audit =
        begin
          Clusters::RecentBlocksAudit.call(limit: RECENT_BLOCKS)
        rescue StandardError => error
          {
            module: "clusters_recent_blocks_audit",
            source: "clusters_recent_blocks_audit",
            generated_at: Time.current,
            status: "error",
            error: "#{error.class}: #{error.message}"
          }
        end

      status =
        health_status(
          issues: issues,
          layer1_status:
            layer1[:status],
          cluster_lag:
            cluster_lag,
          cluster_global_lag:
            cluster_global_lag,
          audit_status:
            audit[:status]
        )

      coverage_snapshot = coverage(recent_scope)
      coverage_snapshot.merge!(audit[:coverage]) if audit[:coverage].is_a?(Hash)

      {
        module: "cluster_health",
        source: "cluster_strict_health_snapshot",
        generated_at: Time.current,
        status: status,
        verdict: verdict(status, layer1[:status], cluster_lag),

        sync: {
          best_height: layer1_tip,
          layer1_tip: layer1_tip,
          layer1_status: layer1[:status],
          bitcoin_core_height:
            bitcoin_core_height,
          cluster_tip:
            cluster_tip,
          global_lag:
            cluster_global_lag,
          cluster_input_max_height: ClusterInput.maximum(:block_height),
          cluster_input_max_spent: ClusterInput.maximum(:spent_block_height),
          scanner_cursor: cluster_tip,
          input_lag: cluster_lag,
          spent_lag: cluster_lag,
          scanner_lag: cluster_lag
        },

        counts: {
          cluster_inputs: ClusterInput.count,
          clusters: Cluster.count,
          addresses: Address.count,
          addresses_clustered_sample:
            Address.where.not(cluster_id: nil).limit(1000).count,
          actor_profiles: ActorProfile.count
        },

        activity: {
          processing:
            process[:busy].to_i.positive? ||
            active_workers.size.positive?,
          last_cluster_input_at: ClusterInput.maximum(:created_at),
          last_address_updated_at: Address.maximum(:updated_at),
          last_cluster_processed_at:
            ClusterInput.where.not(cluster_processed_at: nil)
                        .maximum(:cluster_processed_at),
          last_actor_profile_at: ActorProfile.maximum(:updated_at)
        },

        coverage: coverage_snapshot,
        audit: audit,

        top_nil_cluster_addresses: top_nil_cluster_addresses,
        top_unknown_clusters: top_unknown_clusters,

        automation: {
          queue_name: STRICT_QUEUE,
          process: process,
          queue_size: queue_size,
          scheduled_jobs: scheduled_jobs,
          active_workers: active_workers.size,
          retry_jobs: retry_jobs,
          dead_jobs: dead_jobs,
          automation_ok: automation_ok
        },

        queues: {
          STRICT_QUEUE => queue_size
        },

        workers: active_workers,

        legacy: {
          disabled: true,
          queues: legacy_queue_sizes,
          cron_jobs: legacy_cron_status
        },

        issues: issues
      }
    end

    private

    def strict_cluster_tip
      ClusterProcessedBlock
        .where(status: "processed")
        .maximum(:height)
        .to_i
    end

    def strict_recent_heights
      ClusterProcessedBlock
        .where(status: "processed")
        .order(height: :desc)
        .limit(RECENT_BLOCKS)
        .pluck(:height)
        .sort
    end

    def health_status(
      issues:,
      layer1_status:,
      cluster_lag:,
      cluster_global_lag:,
      audit_status:
    )
      return "critical" if issues.any?
      return "critical" if
        audit_status.to_s == "error"

      return backfill_health_status(
        layer1_status:
          layer1_status,
        cluster_lag:
          cluster_lag,
        cluster_global_lag:
          cluster_global_lag,
        audit_status:
          audit_status
      ) if development_backfill_mode?

      return "critical" if cluster_lag > 20

      if audit_status.present? &&
         audit_status.to_s != "healthy"
        return "warning"
      end

      return "warning" if cluster_lag > 3

      if cluster_lag.positive? ||
         layer1_status.to_s != "healthy"
        return "syncing"
      end

      "healthy"
    end

    def backfill_health_status(
      layer1_status:,
      cluster_lag:,
      cluster_global_lag:,
      audit_status:
    )
      if audit_status.present? &&
         audit_status.to_s != "healthy"
        return "warning"
      end

      if cluster_global_lag >
         development_backfill_max_cluster_global_lag
        return "warning"
      end

      if cluster_lag.positive? ||
         layer1_status.to_s != "healthy"
        return "syncing"
      end

      "healthy"
    end

    def development_backfill_mode?
      ENV[
        "TANSA_PIPELINE_MODE"
      ].to_s ==
        DEVELOPMENT_BACKFILL_MODE
    end

    def development_backfill_max_cluster_global_lag
      [
        Integer(
          ENV.fetch(
            BACKFILL_MAX_CLUSTER_GLOBAL_LAG_ENV,
            DEFAULT_BACKFILL_MAX_CLUSTER_GLOBAL_LAG.to_s
          )
        ),
        0
      ].max
    rescue ArgumentError, TypeError
      DEFAULT_BACKFILL_MAX_CLUSTER_GLOBAL_LAG
    end

    def verdict(status, layer1_status, cluster_lag)
      case status
      when "healthy"
        "Cluster strict est synchronisé avec le dernier bloc Layer1 certifié."
      when "syncing"
        if layer1_status.to_s == "critical"
          "Cluster strict suit les blocs déjà certifiés et attend le rattrapage de Layer1."
        else
          "Cluster strict rattrape #{cluster_lag} bloc(s) certifié(s)."
        end
      when "warning"
        "Cluster strict présente un retard de #{cluster_lag} blocs."
      else
        "Cluster strict nécessite une intervention."
      end
    end

    def coverage(scope)
      total_inputs = scope.count
      total_btc = decimal(scope.sum(:amount_btc))

      clustered_scope =
        scope
          .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
          .where.not(addresses: { cluster_id: nil })

      clustered_btc = decimal(clustered_scope.sum(:amount_btc))
      nil_cluster_inputs = [total_inputs - clustered_scope.count, 0].max
      nil_cluster_btc = total_btc - clustered_btc

      pct =
        if total_btc.zero?
          100.0
        else
          ((clustered_btc / total_btc) * 100).round(2).to_f
        end

      {
        window_blocks: scope.distinct.count(:spent_block_height),
        total_inputs: total_inputs,
        total_btc: total_btc,
        clustered_btc: clustered_btc,
        nil_cluster_btc: nil_cluster_btc,
        btc_coverage_pct: pct,
        nil_cluster_inputs: nil_cluster_inputs,
        addresses_total: Address.count,
        addresses_nil_cluster: Address.where(cluster_id: nil).count
      }
    rescue StandardError => error
      {
        error: "#{error.class}: #{error.message}"
      }
    end

    def top_nil_cluster_addresses
      columns = Address.column_names

      if columns.include?("balance_btc")
        return Address
          .where(cluster_id: nil)
          .where.not(address: [nil, ""])
          .order(balance_btc: :desc)
          .limit(20)
          .pluck(:address, :balance_btc)
          .to_h
      end

      if columns.include?("total_received_sats") &&
         columns.include?("total_sent_sats")
        rows =
          Address
            .where(cluster_id: nil)
            .where.not(address: [nil, ""])
            .select(
              "address",
              "(COALESCE(total_received_sats, 0) - " \
              "COALESCE(total_sent_sats, 0)) AS balance_sats"
            )
            .order(Arel.sql("balance_sats DESC"))
            .limit(20)

        return rows.to_h do |row|
          [
            row.address,
            BigDecimal(row.attributes["balance_sats"].to_s) /
              BigDecimal("100000000")
          ]
        end
      end

      {}
    rescue StandardError
      {}
    end

    def top_unknown_clusters
      columns = Cluster.column_names

      balance_column =
        %w[balance_btc current_balance_btc total_balance_btc]
          .find { |column| columns.include?(column) }

      return {} unless balance_column

      Cluster
        .order(Arel.sql("#{balance_column} DESC"))
        .limit(20)
        .pluck(:id, balance_column)
        .to_h
    rescue StandardError
      {}
    end

    def automation_available?(process:)
      process[:present] == true
    end

    def strict_process
      process =
        Sidekiq::ProcessSet.new.find do |candidate|
          Array(candidate["queues"]).include?(STRICT_QUEUE)
        end

      return { present: false } unless process

      {
        present: true,
        pid: process["pid"],
        busy: process["busy"].to_i,
        concurrency: process["concurrency"].to_i,
        queues: process["queues"]
      }
    rescue StandardError => error
      {
        present: false,
        error: error.message
      }
    end

    def strict_workers
      require "json"

      Sidekiq::WorkSet.new.filter_map do |_process_id, _thread_id, work|
        payload =
          sidekiq_work_payload(work)

        next unless payload["queue"].to_s == STRICT_QUEUE

        {
          queue: payload["queue"],
          klass: sidekiq_payload_job_class(payload),
          args: payload["args"]
        }
      end
    rescue StandardError
      []
    end

    def sidekiq_work_payload(work)
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

    def sidekiq_payload_job_class(payload)
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

    def scheduled_count
      Sidekiq::ScheduledSet.new.count do |job|
        job.queue.to_s == STRICT_QUEUE
      end
    rescue StandardError
      0
    end

    def retry_count
      Sidekiq::RetrySet.new.count do |job|
        job.queue.to_s == STRICT_QUEUE
      end
    rescue StandardError
      0
    end

    def dead_count
      Sidekiq::DeadSet.new.count do |job|
        job.queue.to_s == STRICT_QUEUE
      end
    rescue StandardError
      0
    end

    def legacy_queue_sizes
      %w[
        p3_clusters_scan
        process
        realtime
      ].to_h do |queue_name|
        [queue_name, Sidekiq::Queue.new(queue_name).size]
      end
    rescue StandardError => error
      { error: error.message }
    end

    def legacy_cron_status
      require "sidekiq/cron/job"

      %w[
        layer1_orchestrator
        cluster_input_orchestrator
      ].to_h do |name|
        job = Sidekiq::Cron::Job.find(name)
        [name, job ? job.status.to_s : "absent"]
      end
    rescue StandardError => error
      { error: error.message }
    end

    def decimal(value)
      BigDecimal(value.to_s)
    end
  end
end
