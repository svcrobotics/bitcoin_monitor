# frozen_string_literal: true

require "rake"

class ClusterV3DetectSignalsJob < ApplicationJob
  queue_as :p4_analytics

  def perform
    Rails.application.load_tasks

    ENV["TRIGGERED_BY"] = "sidekiq_cron"
    
    Rake::Task["cluster:v3:detect_signals"].reenable
    Rake::Task["cluster:v3:detect_signals"].invoke
  end
end
