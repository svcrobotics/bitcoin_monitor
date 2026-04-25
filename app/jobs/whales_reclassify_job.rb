# frozen_string_literal: true

require "rake"

class WhalesReclassifyJob < ApplicationJob
  queue_as :default

  def perform
    Rails.application.load_tasks

    Rake::Task["whales:reclassify_last_7d"].reenable
    Rake::Task["whales:reclassify_last_7d"].invoke
  end
end
