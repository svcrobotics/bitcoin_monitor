# frozen_string_literal: true

module Clusters
  class ClusterInputBuildJob
    include Sidekiq::Job

    sidekiq_options queue: :p3_clusters, retry: 3

    def perform(from_height, to_height, after_id = nil)
      result = Clusters::ClusterInputBuilder.call(
        from_height: from_height,
        to_height: to_height,
        after_id: after_id
      )

      Rails.logger.info(
        "[cluster_input_build_job] " \
        "from=#{from_height} " \
        "to=#{to_height} " \
        "after_id=#{after_id} " \
        "rows=#{result[:rows]} " \
        "inserted=#{result[:inserted]} " \
        "last_tx_output_id=#{result[:last_tx_output_id]} " \
        "has_more=#{result[:has_more]}"
      )

      if result[:has_more] && result[:last_tx_output_id].present?
        self.class.perform_async(
          from_height,
          to_height,
          result[:last_tx_output_id]
        )
      end
    end
  end
end