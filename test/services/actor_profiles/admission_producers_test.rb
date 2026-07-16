# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class AdmissionProducersTest < ActiveSupport::TestCase
    test "AddressSpend certification durably admits every affected cluster" do
      height = 1_700_001
      block_hash = "admission-source-#{height}"
      cluster = Cluster.create!(composition_version: 1)
      address = Address.create!(address: "admission-#{SecureRandom.hex(8)}", cluster: cluster)
      ClusterProcessedBlock.create!(height: height, block_hash: block_hash,
        status: "processed", processed_at: Time.current)
      ClusterInput.create!(block_height: height - 1, txid: SecureRandom.hex(32), vout: 0,
        address: address.address, amount_btc: 1, spent: true,
        spent_txid: SecureRandom.hex(32), spent_block_height: height)

      result = AddressSpendStats::ProjectBlock.call(height: height)
      admission = ActorProfileBuildAdmission.find_by!(cluster: cluster,
        cluster_composition_version: 1, source_height: height, source_hash: block_hash)

      assert_equal "pending", admission.status
      assert_equal "address_spend", admission.reason
      assert_equal 1, result.dig(:actor_profile_admissions, :created)
      assert JSON.generate(result)

      replay = AddressSpendStats::ProjectBlock.call(height: height)
      assert_equal 0, replay.dig(:actor_profile_admissions, :created)
      assert_equal 1, ActorProfileBuildAdmission.where(cluster: cluster).count
    end

    test "active producers no longer use Redis DirtyMarker for ActorProfile admission" do
      files = %w[
        app/services/actor_profiles/ensure_for_active_clusters.rb
        app/services/clusters/dirty_cluster_refresher.rb
        app/services/clusters/ensure_address_clusters.rb
        app/services/address_spend_stats/project_block.rb
      ]
      source = files.to_h { |path| [path, File.read(Rails.root.join(path))] }
      source.each do |path, content|
        assert_no_match(/DirtyMarker|Redis|perform_(?:async|later|in)/, content, path)
      end
      assert_match(/Admission\.register_source/, source.fetch(files.last))
    end
  end
end
