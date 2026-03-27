# lib/tasks/cluster_v2.rake
namespace :cluster do
  desc "Build cluster profiles (V2)"
  task build_profiles: :environment do
    total = Cluster.count
    puts "[cluster:v2] building profiles for #{total} clusters"

    Cluster.find_each.with_index do |cluster, i|
      ClusterAggregator.call(cluster)

      if (i % 100).zero?
        puts "[cluster:v2] #{i}/#{total}"
      end
    end

    puts "[cluster:v2] done"
  end
end