# frozen_string_literal: true

namespace :cluster do
  desc "Rebuild all cluster profiles from current addresses data"
  task rebuild_profiles: :environment do
    total = Cluster.count
    done = 0
    errors = 0

    puts "[cluster:rebuild_profiles] start total=#{total}"

    Cluster.find_each(batch_size: 500) do |cluster|
      begin
        ClusterAggregator.call(cluster)
      rescue => e
        errors += 1
        puts "[cluster:rebuild_profiles] error cluster_id=#{cluster.id} #{e.class}: #{e.message}"
      ensure
        done += 1
      end

      if (done % 500).zero? || done == total
        puts "[cluster:rebuild_profiles] progress #{done}/#{total} errors=#{errors}"
      end
    end

    puts "[cluster:rebuild_profiles] done total=#{done} errors=#{errors}"
  end
end