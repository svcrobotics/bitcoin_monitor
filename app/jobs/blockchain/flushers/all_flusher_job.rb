# frozen_string_literal: true

module Blockchain
  module Flushers
    class AllFlusherJob < ApplicationJob
      queue_as :flushers

      def perform
        OutputFlusherJob.perform_later
        SpentOutputFlusherJob.perform_later

        Rails.logger.info("[all_flusher_job] output_and_spent_flushers_enqueued")
      end
    end
  end
end