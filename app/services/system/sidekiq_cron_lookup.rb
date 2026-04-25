# frozen_string_literal: true

require "sidekiq-cron"

module System
  class SidekiqCronLookup
    def self.call
      new.call
    end

    def call
      Sidekiq::Cron::Job.all.each_with_object({}) do |job, hash|
        hash[job.name.to_s] = {
          name: job.name,
          cron: job.cron,
          klass: job.klass,
          status: job.status
        }
      end
    rescue StandardError
      {}
    end
  end
end
