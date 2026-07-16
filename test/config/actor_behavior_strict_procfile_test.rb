# frozen_string_literal: true

require "test_helper"

class ActorBehaviorStrictProcfileTest < ActiveSupport::TestCase
  test "declares exactly one exclusive single-concurrency consumer" do
    lines = Rails.root.join("Procfile.dev").read.lines.grep(/^sidekiq_actor_behavior_strict:/)
    assert_equal 1, lines.size
    line = lines.first
    assert_includes line, "bundle exec sidekiq"
    assert_includes line, "-c 1"
    assert_includes line, "-q actor_behavior_strict"
    assert_includes line, "nice -n 19"
    assert_equal 1, line.scan(/(?:^|\s)-q\s+/).size
    refute_match(/scheduler|ActorLabel|rails runner/, line)
  end
end
