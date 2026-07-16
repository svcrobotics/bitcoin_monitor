# frozen_string_literal: true
require "test_helper"
class ActorLabelsStrictProcfileTest < ActiveSupport::TestCase
  test "declares one exclusive single concurrency consumer" do
    lines = Rails.root.join("Procfile.dev").read.lines.grep(/^sidekiq_actor_labels_strict:/)
    assert_equal 1, lines.size
    assert_includes lines.first, "-c 1"
    assert_includes lines.first, "-q actor_labels_strict"
    assert_equal 1, lines.first.scan(/ -q /).size
  end
end
