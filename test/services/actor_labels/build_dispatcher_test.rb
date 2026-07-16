# frozen_string_literal: true
require "test_helper"
module ActorLabels
  class BuildDispatcherTest < ActiveSupport::TestCase
    test "empty result is serializable" do
      result = BuildDispatcher.call
      assert_equal 0, result[:claimed]
      assert JSON.generate(result)
    end
  end
end
