# lib/tasks/cluster_v3.rake

namespace :cluster do
  namespace :v3 do
    desc "Build cluster metrics"
    task build_metrics: :environment do
      date = Date.current

      JobRun.log!("cluster_v3_build_metrics", meta: { date: date }.to_json) do
        puts "[cluster:v3_build_metrics] start date=#{date}"

        count = 0

        Cluster.find_each do |cluster|
          ClusterMetricsBuilder.call(cluster)
          count += 1
        end

        puts "[cluster:v3_build_metrics] done clusters=#{count}"

        { clusters_processed: count }
      end
    end
  end
end