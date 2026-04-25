# frozen_string_literal: true

namespace :cluster do
  namespace :v3 do
    desc "Detect cluster signals (DATE=YYYY-MM-DD optional)"
    task detect_signals: :environment do
      date =
        if ENV["DATE"].present?
          Date.parse(ENV["DATE"])
        else
          Date.current
        end

      since = 2.days.ago

      scope = Cluster
        .joins(:cluster_profile)
        .where("cluster_profiles.updated_at >= ?", since)

      total = scope.count

      JobRunner.run!(
        "cluster_v3_detect_signals",
        meta: {
          date: date,
          since: since,
          total: total
        },
        triggered_by: ENV.fetch("TRIGGERED_BY", "cron")
      ) do |jr|

        JobRunner.heartbeat!(jr)

        puts "[cluster:v3_detect_signals] start date=#{date} since=#{since} total=#{total}"

        processed = 0

        scope.find_each.with_index(1) do |cluster, i|
          ClusterSignalEngine.call(
            cluster,
            snapshot_date: date
          )

          processed = i

          if (i % 100).zero?
            JobRunner.progress!(
              jr,
              pct: total.positive? ? ((i.to_f / total) * 100).round(1) : 100.0,
              label: "cluster #{i} / #{total}",
              meta: {
                snapshot_date: date,
                since: since,
                processed: i,
                total: total
              }
            )

            JobRunner.heartbeat!(jr)

            puts "[cluster:v3_detect_signals] processed=#{i}/#{total}"
          end
        end

        JobRunner.heartbeat!(jr)

        puts "[cluster:v3_detect_signals] done processed=#{processed}"

        result = {
          snapshot_date: date,
          since: since,
          clusters_processed: processed,
          total: total
        }

        jr.update!(
          meta: {
            date: date,
            since: since,
            total: total,
            result: result
          }.to_json
        )

        result
      end

    rescue ArgumentError => e
      abort "[cluster:v3_detect_signals] invalid DATE format: #{e.message}"
    end
  end
end