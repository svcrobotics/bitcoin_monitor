# frozen_string_literal: true

namespace :cluster do
  namespace :v3 do
    desc "Detect cluster signals (DATE=YYYY-MM-DD optional)"
    task detect_signals: :environment do
      date = ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current
      scope = Cluster.all
      total = scope.count

      JobRun.log!("cluster_v3_detect_signals", meta: { date: date, total: total }.to_json) do
        puts "[cluster:v3_detect_signals] start date=#{date} total=#{total}"

        processed = 0

        scope.find_each.with_index(1) do |cluster, i|
          ClusterSignalEngine.call(cluster, snapshot_date: date)
          processed = i

          puts "[cluster:v3_detect_signals] processed=#{i}/#{total}" if (i % 100).zero?
        end

        puts "[cluster:v3_detect_signals] done processed=#{processed}"

        {
          snapshot_date: date,
          clusters_processed: processed,
          total: total
        }
      end
    rescue ArgumentError => e
      abort "[cluster:v3_detect_signals] invalid DATE format: #{e.message}"
    end
  end
end