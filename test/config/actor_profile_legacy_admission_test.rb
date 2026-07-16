# frozen_string_literal: true

require "test_helper"

class ActorProfileLegacyAdmissionTest < ActiveSupport::TestCase
  test "sidekiq cron has no automatic Redis ActorProfile dispatcher" do
    source = File.read(Rails.root.join("config/initializers/sidekiq_cron.rb"))
    assert_no_match(/ActorProfilesDispatcherJob/, source)
    assert_no_match(/actor_profiles_dispatcher/, source)
    assert_match(/StrictPipeline::SchedulerWatchdogJob/, source)
  end
end
