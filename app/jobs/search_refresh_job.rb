# frozen_string_literal: true

class SearchRefreshJob < ApplicationJob
  queue_as :low

  def perform
    return unless System::SidekiqBackpressure.allow?(
      queue: "low",
      job_class: self.class.name,
      max_queue_size: 1
    )

    System::RedisJobLock.with_lock("search_refresh", ttl: 1.hour.to_i) do
      JobRunner.run!(
        "search_refresh",
        triggered_by: ENV.fetch("TRIGGERED_BY", "sidekiq_cron"),
        scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
      ) do |jr|
        results = {}

        JobRunner.progress!(jr, pct: 0, label: "starting search refresh", meta: { step: "start" })

        JobRunner.progress!(jr, pct: 10, label: "index modules", meta: { step: "modules", current_step: 1, total_steps: 5 })
        results[:modules] = Search::ModuleIndexer.call

        JobRunner.progress!(jr, pct: 30, label: "index cluster events", meta: { step: "cluster_events", current_step: 2, total_steps: 5, limit: 500 })
        results[:cluster_events] = Search::ClusterEventIndexer.call(limit: 500)

        JobRunner.progress!(jr, pct: 50, label: "index clusters", meta: { step: "clusters", current_step: 3, total_steps: 5, limit: 1_000 })
        results[:clusters] = Search::ClusterIndexer.call(limit: 1_000)

        JobRunner.progress!(jr, pct: 70, label: "index whale alerts", meta: { step: "whale_alerts", current_step: 4, total_steps: 5, limit: 1_000 })
        results[:whale_alerts] = Search::WhaleAlertIndexer.call(limit: 1_000)

        JobRunner.progress!(jr, pct: 90, label: "index exchange addresses", meta: { step: "exchange_addresses", current_step: 5, total_steps: 5, limit: 5_000 })
        results[:exchange_addresses] = Search::ExchangeAddressIndexer.call(limit: 5_000)

        Rails.logger.info("[search_refresh] #{results.inspect}")

        JobRunner.progress!(jr, pct: 100, label: "search refresh complete", meta: results.is_a?(Hash) ? results : {})

        results
      end
    end
  end

  
end