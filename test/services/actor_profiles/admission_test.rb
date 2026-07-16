# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class AdmissionTest < ActiveSupport::TestCase
    setup do
      @cluster = Cluster.create!(composition_version: 1)
      certify_source(100, "hash-100")
    end

    test "registers composition and fact versions idempotently" do
      first = register(source_height: 100, source_hash: "hash-100")
      replay = register(source_height: 100, source_hash: "hash-100")
      assert_equal "created", first[:status]
      assert_equal "already_registered", replay[:status]
      assert_equal 1, ActorProfileBuildAdmission.count

      certify_source(101, "hash-101")
      progressed = register(source_height: 101, source_hash: "hash-101")
      assert_equal "created", progressed[:status]
      assert_equal 2, ActorProfileBuildAdmission.count

      @cluster.update!(composition_version: 2)
      composition = register(composition_version: 2, source_height: 101, source_hash: "hash-101")
      assert_equal "created", composition[:status]
      assert_equal 3, ActorProfileBuildAdmission.count
      assert JSON.generate(composition)
    end

    test "refuses uncertified divergent and stale provenance" do
      assert_raises(ArgumentError) { register(source_height: 101, source_hash: "missing") }
      assert_raises(ArgumentError) { register(source_height: 100, source_hash: "wrong") }
      assert_raises(ArgumentError) { register(composition_version: 2) }
      assert_equal 0, ActorProfileBuildAdmission.count
    end

    test "database uniqueness is the concurrency boundary" do
      register
      duplicate = ActorProfileBuildAdmission.new(ActorProfileBuildAdmission.first.attributes.except(
        "id", "created_at", "updated_at"
      ))
      assert_raises(ActiveRecord::RecordNotUnique) do
        duplicate.save!(validate: false)
      end
      assert_equal 1, ActorProfileBuildAdmission.count
    end

    private

    def register(composition_version: 1, source_height: 100, source_hash: "hash-100")
      Admission.register(cluster_id: @cluster.id, composition_version: composition_version,
        source_height: source_height, source_hash: source_hash, reason: "address_spend")
    end

    def certify_source(height, block_hash)
      ClusterProcessedBlock.create!(height: height, block_hash: block_hash, status: "processed",
        processed_at: Time.current)
      AddressSpendProjectionBlock.create!(height: height, block_hash: block_hash,
        status: "completed", completed_at: Time.current)
    end
  end
end
