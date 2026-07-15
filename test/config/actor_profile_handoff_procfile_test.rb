# frozen_string_literal: true

require "test_helper"

class ActorProfileHandoffProcfileTest < ActiveSupport::TestCase
  test "declares one exclusive single-concurrency ActorProfile consumer" do
    declarations = File.readlines(Rails.root.join("Procfile.dev"), chomp: true)
      .grep(/\Asidekiq_actor_profile_strict:/)
    assert_equal 1, declarations.size
    command = declarations.first
    assert_includes command, "bundle exec sidekiq"
    assert_includes command, "-c 1"
    assert_includes command, "-q actor_profile_strict"
    assert_includes command, "nice -n 18"
    refute_match(/-q\s+cluster_strict/, command)
    refute_match(/scheduler/i, command)
  end
end
