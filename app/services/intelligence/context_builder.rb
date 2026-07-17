# app/services/intelligence/context_builder.rb
# frozen_string_literal: true

module Intelligence
  class ContextBuilder
    HISTORY_DAYS = 7

    def self.etf_candidates
      data = ActorLabels::EtfCandidatesAnswer.call

      {
        module: "etf_candidates",
        source: "actor_profile_etf_candidate",
        generated_at: Time.current,

        summary: {
          count: data[:count],
          total_balance_btc: data[:total_balance_btc]
        },

        candidates: data[:candidates],

        watch_priority: {
          watch: "Surveiller si les ETF candidates accumulent ou distribuent via leurs balances et leurs flux on-chain."
        },

        interpretation: "Tansa détecte ces clusters comme ETF candidates à partir de critères internes on-chain. Ce ne sont pas des ETF confirmés par une source externe."
      }
    end

    def self.layer1_health
      snapshot = Layer1::OperationalSnapshot.call
      buffers = snapshot[:buffers] || {}

      pipeline_state =
        if snapshot[:error].present?
          "unknown"
        elsif snapshot[:lag].to_i.zero? &&
              buffers[:outputs].to_i.zero? &&
              buffers[:spent].to_i.zero?
          "idle_synced"
        else
          "active"
        end

      {
        module: "layer1_health",
        source: "layer1_operational_snapshot",
        generated_at: snapshot[:generated_at] || Time.current,

        raw_snapshot: snapshot.merge(
          module: "layer1_health",
          source: "layer1_operational_snapshot"
        ),

        architecture: {
          pipeline: [
            "Bitcoin Core",
            "BlockBufferModel",
            "BlockProcessJob",
            "Redis outputs buffer",
            "OutputFlusher",
            "UtxoOutput",
            "SpentOutputFlusher",
            "ClusterInput"
          ],
          note: "tx_outputs est retirée du chemin critique. Layer 1 utilise maintenant utxo_outputs comme table vivante des UTXO."
        },

        status: snapshot[:status],

        sync: {
          best_height: snapshot[:bitcoin_core_height],
          processed_height: snapshot[:processed_height],
          lag: snapshot[:lag]
        },

        buffers: buffers,

        activity: {
          pipeline_state: pipeline_state,
          generated_at: snapshot[:generated_at],
          error: snapshot[:error]
        },

        queues: {},

        watch_priority: {
          watch: "Surveiller le lag Layer 1, les buffers Redis outputs/spent et la progression du dernier bloc traité."
        },

        interpretation_rules: {
          healthy: "lag = 0 et buffers vides",
          warning: "lag positif ou buffers en cours de traitement",
          critical: "état Layer1 impossible à vérifier"
        }
      }
    end

    def self.cluster_health
      Clusters::OperationalSnapshot.call
    end

    def self.actor_profiles_health
      ActorProfiles::StrictHealthSnapshot.call.merge(
        module: "actor_profiles_health"
      )
    end

    def self.actor_behaviors_health
      ActorBehaviors::StrictHealthSnapshot.call.merge(
        module: "actor_behaviors_health",
        source: "actor_behaviors_strict_health_snapshot",
        control: ActorBehaviors::ControlSnapshot.call
      )
    end

    def self.actor_labels_health
      ActorLabels::StrictHealthSnapshot.call.merge(
        module: "actor_labels_health",
        generated_at: Time.current
      )
    end

    def self.exchange_flow
      today = Dashboard::ExchangeCoreNetflowToday.call
      history = exchange_flow_history

      {
        module: "exchange_flow",
        source: "actor_profile_exchange_like",

        architecture: {
          pipeline: [
            "Layer 1",
            "Clusters",
            "Actor Profiles",
            "Actor Labels",
            "Exchange Core Flow"
          ],
          note: "Les flux sont calculés uniquement depuis les acteurs exchange_like validés par Actor Profiles."
        },

        coverage: {
          requested_days: HISTORY_DAYS,
          measured_days: history.count { |row| row[:events_count].to_i.positive? },
          reliable_days: history.count { |row| row[:events_count].to_i.positive? && row[:netflow_btc].to_f.abs >= 500 },
          note: "La nouvelle architecture Exchange Core Flow est en phase de montée en charge. Les jours sans événements ou avec faible couverture doivent être interprétés avec prudence."
        },

        dominant_signal: {
          signal: today[:signal]
        },

        watch_priority: {
          watch: "Surveiller si le netflow BTC reste positif ou augmente dans la journée."
        },

        interpretation: today[:interpretation],

        today: {
          inflow_btc: today[:inflow_btc].to_f.round(2),
          outflow_btc: today[:outflow_btc].to_f.round(2),
          netflow_btc: today[:netflow_btc].to_f.round(2),
          events_count: today[:events_count].to_i,
          updated_at: today[:updated_at]
        },

        history_7d: history
      }
    end

    def self.exchange_flow_history
      from_day = Date.current - (HISTORY_DAYS - 1).days

      (from_day..Date.current).map do |day|
        range = day.beginning_of_day..day.end_of_day
        rows = ExchangeCoreFlowEvent.where(event_time: range)

        inflow_btc = rows.where(direction: "inflow").sum(:amount_btc).to_f.round(2)
        outflow_btc = rows.where(direction: "outflow").sum(:amount_btc).to_f.round(2)
        netflow_btc = (inflow_btc - outflow_btc).round(2)

        {
          day: day,
          inflow_btc: inflow_btc,
          outflow_btc: outflow_btc,
          netflow_btc: netflow_btc,
          events_count: rows.count,
          signal: signal_for(netflow_btc)
        }
      end.reverse
    end

    def self.signal_for(netflow_btc)
      if netflow_btc >= 2_000
        "selling_pressure_strong"
      elsif netflow_btc >= 500
        "selling_pressure_moderate"
      elsif netflow_btc >= 100
        "selling_pressure_weak"
      elsif netflow_btc <= -2_000
        "accumulation_strong"
      elsif netflow_btc <= -500
        "accumulation_moderate"
      elsif netflow_btc <= -100
        "accumulation_weak"
      else
        "neutral"
      end
    end

    def self.system_health
      require "sidekiq/api"

      queues = Sidekiq::Queue.all.map do |q|
        {
          name: q.name,
          size: q.size,
          latency: q.latency.round(1)
        }
      end

      workers_count = Sidekiq::Workers.new.size

      snapshot = System::RecoverySnapshotBuilder.call rescue {}
      layer1_snapshot = snapshot[:layer1] || {}

      best_height = layer1_snapshot[:best_height]
      last_processed_height = layer1_snapshot[:last_processed_height]

      spent_max_height = layer1_snapshot[:spent_max_height]
      exchange_flow_max_height = layer1_snapshot[:exchange_flow_max_height]

      lag =
        if best_height.present? && last_processed_height.present?
          [best_height.to_i - last_processed_height.to_i, 0].max
        else
          layer1_snapshot[:lag].to_i
        end

      spent_lag =
        if last_processed_height.present? && spent_max_height.present?
          [last_processed_height.to_i - spent_max_height.to_i, 0].max
        else
          0
        end

      flow_lag =
        if last_processed_height.present? && exchange_flow_max_height.present?
          [last_processed_height.to_i - exchange_flow_max_height.to_i, 0].max
        else
          0
        end

      redis_buffers = layer1_snapshot[:redis_buffers] || {}

      outputs_buffer = redis_buffers[:outputs_buffer].to_i
      spent_outputs_buffer = redis_buffers[:spent_outputs_buffer].to_i

      busy_queues =
        queues.select { |q| q[:size].to_i > 0 || q[:latency].to_f > 30 }

      critical_queues =
        queues.select { |q| q[:size].to_i > 1000 }

      warning_queues =
        queues.select { |q| q[:size].to_i > 100 }

      async_warning =
        spent_lag > 100 ||
        flow_lag > 100 ||
        outputs_buffer > 10_000 ||
        spent_outputs_buffer > 10_000

      status =
        if critical_queues.any? || async_warning
          "critical"
        elsif warning_queues.any? || busy_queues.any? || lag.positive?
          "warning"
        else
          "ok"
        end

      {
        module: "system_health",
        source: "lightweight_system_context",
        generated_at: Time.current,

        summary: {
          status: status,
          busy_queues_count: busy_queues.size,
          critical_queues_count: critical_queues.size,
          warning_queues_count: warning_queues.size,
          running_workers: workers_count
        },

        layer1: {
          best_height: best_height,
          last_processed_height: last_processed_height,
          lag: lag,

          spent_max_height: spent_max_height,
          exchange_flow_max_height: exchange_flow_max_height,

          spent_lag: spent_lag,
          flow_lag: flow_lag,

          redis_buffers: {
            outputs: outputs_buffer,
            spent: spent_outputs_buffer,
            total: outputs_buffer + spent_outputs_buffer
          }
        },

        queues: queues,

        watch_priority: {
          watch: "Surveiller le retard async Layer 1, les buffers Redis, les queues Sidekiq avec backlog et les latences élevées."
        }
      }
    end

    def self.system_status(layer1, busy_queues)
      return "warning" if layer1[:lag].to_i.positive?
      return "warning" if busy_queues.any?

      "ok"
    end

  end
end