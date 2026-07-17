# frozen_string_literal: true

require "test_helper"

module Clusters
  class StrictHealthSnapshotAutomationTest <
    ActiveSupport::TestCase

    test "present worker is sufficient for central scheduler automation" do
      snapshot =
        StrictHealthSnapshot.new

      assert(
        snapshot.send(
          :automation_available?,
          process: {
            present: true,
            busy: 0
          }
        )
      )
    end

    test "missing worker means automation is unavailable" do
      snapshot =
        StrictHealthSnapshot.new

      refute(
        snapshot.send(
          :automation_available?,
          process: {
            present: false
          }
        )
      )
    end
  end
end
