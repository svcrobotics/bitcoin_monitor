# frozen_string_literal: true

require "test_helper"

class ActorProfileBuildAdmissionTest < ActiveSupport::TestCase
  setup do
    @cluster = Cluster.create!(composition_version: 1)
  end

  test "validates identity transitions and immutable source provenance" do
    admission = build_admission
    assert admission.valid?
    assert_not build_admission(cluster_composition_version: 0).valid?
    assert_not build_admission(source_height: -1).valid?
    assert_not build_admission(source_hash: "").valid?
    assert_not build_admission(reason: "unknown").valid?

    admission.save!
    admission.claim!(at: Time.current)
    assert_equal 1, admission.attempts
    admission.fail!(error_class: "RuntimeError")
    admission.claim!(at: Time.current)
    admission.complete!(at: Time.current)
    assert_equal "completed", admission.status
    assert_raises(ActiveRecord::RecordInvalid) { admission.update!(source_height: 2) }
  end

  private

  def build_admission(**attributes)
    ActorProfileBuildAdmission.new({ cluster: @cluster, cluster_composition_version: 1,
      source_height: 1, source_hash: "hash", reason: "address_spend" }.merge(attributes))
  end
end
