class PingJob < ApplicationJob
  queue_as :default

  def perform(*args)
    Rails.logger.info("[PingJob] ok #{Time.current}")
  end
end
