# frozen_string_literal: true

module Actors
  class ExchangeCoreFlowsForBlockJob
    include Sidekiq::Job

    sidekiq_options queue: :p1_exchange, retry: 5

    def perform(block_height)
      Rails.logger.info(
        "[exchange_core_flows_for_block_job] start height=#{block_height}"
      )

      result = DetectExchangeCoreFlowsForBlock.call(
        block_height: block_height
      )

      Rails.logger.info(
        "[exchange_core_flows_for_block_job] done height=#{block_height} result=#{result.inspect}"
      )
    rescue StandardError => e
      Rails.logger.error(
        "[exchange_core_flows_for_block_job] error height=#{block_height} #{e.class}: #{e.message}"
      )
      raise
    end
  end
end
