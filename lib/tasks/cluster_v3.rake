# lib/tasks/cluster_v3.rake

namespace :cluster do
  namespace :v3 do
    desc "Build cluster metrics"
    task build_metrics: :environment do
      date = Date.current
      total = Cluster.count

      JobRunner.run!("cluster_v3_build_metrics", meta: { date: date, total: total }, triggered_by: "cron") do |jr|
        JobRunner.heartbeat!(jr)

        puts "[cluster:v3_build_metrics] start date=#{date} total=#{total}"

        count = 0

        Cluster.find_each.with_index(1) do |cluster, i|
          ClusterMetricsBuilder.call(cluster)
          count = i

          if (i % 100).zero?
            JobRunner.progress!(
              jr,
              pct: total.positive? ? ((i.to_f / total) * 100).round(1) : 100.0,
              label: "cluster #{i} / #{total}",
              meta: {
                date: date,
                processed: i,
                total: total
              }
            )

            puts "[cluster:v3_build_metrics] processed=#{i}/#{total}"
          end
        end

        JobRunner.heartbeat!(jr)

        puts "[cluster:v3_build_metrics] done clusters=#{count}"

        result = { clusters_processed: count }

        jr.update!(
          meta: { date: date, total: total }.merge(result: result).to_json
        )

        result
      end
    end
  end
end