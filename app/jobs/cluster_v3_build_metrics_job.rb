# frozen_string_literal: true

require "rake"

class ClusterV3BuildMetricsJob < ApplicationJob
  queue_as :default

  def perform
    Rails.application.load_tasks

    ENV["SINCE"] ||= "2 days ago"
    ENV["TRIGGERED_BY"] = "sidekiq_cron"
    
    Rake::Task["cluster:v3:build_metrics"].reenable
    Rake::Task["cluster:v3:build_metrics"].invoke
  end
end