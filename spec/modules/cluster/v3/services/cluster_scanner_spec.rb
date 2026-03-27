# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClusterScanner do
  let(:rpc) { instance_double(BitcoinRpc) }

  describe ".call" do
    context "with a simple multi-input transaction" do
      let(:blockhash_100) { "blockhash-100" }

      let(:tx_multi_input) do
        {
          "txid" => "tx-multi-1",
          "vin" => [
            {
              "prevout" => {
                "value" => "1.25",
                "scriptPubKey" => { "address" => "bc1qscan111111111111111111111111111111111111" }
              }
            },
            {
              "prevout" => {
                "value" => "0.75",
                "scriptPubKey" => { "address" => "bc1qscan222222222222222222222222222222222222" }
              }
            }
          ]
        }
      end

      let(:block_100) do
        { "tx" => [tx_multi_input] }
      end

      before do
        allow(rpc).to receive(:getblockcount).and_return(100)
        allow(rpc).to receive(:getblockhash).with(100).and_return(blockhash_100)
        allow(rpc).to receive(:getblock).with(blockhash_100, 3).and_return(block_100)
      end

      it "creates a cluster, links addresses, and updates profile data" do
        result = described_class.call(from_height: 100, to_height: 100, rpc: rpc)

        expect(result[:ok]).to eq(true)
        expect(result[:multi_input_txs]).to eq(1)
        expect(result[:clusters_created]).to eq(1)
        expect(result[:links_created]).to eq(1)

        a1 = Address.find_by(address: "bc1qscan111111111111111111111111111111111111")
        a2 = Address.find_by(address: "bc1qscan222222222222222222222222222222222222")

        expect(a1).to be_present
        expect(a2).to be_present
        expect(a1.cluster_id).to be_present
        expect(a2.cluster_id).to eq(a1.cluster_id)

        cluster = a1.cluster
        expect(cluster).to be_present

        link = AddressLink.find_by(txid: "tx-multi-1", link_type: "multi_input")
        expect(link).to be_present

        profile = cluster.cluster_profile
        expect(profile).to be_present
        expect(profile.cluster_size).to eq(2)
        expect(profile.tx_count).to eq(2)
        expect(profile.total_sent_sats).to eq(200_000_000)
      end
    end

    context "when a later transaction attaches a new address to an existing cluster" do
      let(:blockhash_100) { "blockhash-100" }
      let(:blockhash_101) { "blockhash-101" }

      let(:tx_1) do
        {
          "txid" => "tx-multi-1",
          "vin" => [
            {
              "prevout" => {
                "value" => "1.0",
                "scriptPubKey" => { "address" => "bc1qscan333333333333333333333333333333333333" }
              }
            },
            {
              "prevout" => {
                "value" => "1.0",
                "scriptPubKey" => { "address" => "bc1qscan444444444444444444444444444444444444" }
              }
            }
          ]
        }
      end

      let(:tx_2) do
        {
          "txid" => "tx-multi-2",
          "vin" => [
            {
              "prevout" => {
                "value" => "0.5",
                "scriptPubKey" => { "address" => "bc1qscan333333333333333333333333333333333333" }
              }
            },
            {
              "prevout" => {
                "value" => "0.25",
                "scriptPubKey" => { "address" => "bc1qscan555555555555555555555555555555555555" }
              }
            }
          ]
        }
      end

      before do
        allow(rpc).to receive(:getblockcount).and_return(101)

        allow(rpc).to receive(:getblockhash).with(100).and_return(blockhash_100)
        allow(rpc).to receive(:getblockhash).with(101).and_return(blockhash_101)

        allow(rpc).to receive(:getblock).with(blockhash_100, 3).and_return({ "tx" => [tx_1] })
        allow(rpc).to receive(:getblock).with(blockhash_101, 3).and_return({ "tx" => [tx_2] })
      end

      it "keeps one cluster and adds the new address to it" do
        described_class.call(from_height: 100, to_height: 101, rpc: rpc)

        a1 = Address.find_by(address: "bc1qscan333333333333333333333333333333333333")
        a2 = Address.find_by(address: "bc1qscan444444444444444444444444444444444444")
        a3 = Address.find_by(address: "bc1qscan555555555555555555555555555555555555")

        expect(a1.cluster_id).to be_present
        expect(a2.cluster_id).to eq(a1.cluster_id)
        expect(a3.cluster_id).to eq(a1.cluster_id)

        cluster = a1.cluster
        expect(cluster.cluster_profile).to be_present
        expect(cluster.cluster_profile.cluster_size).to eq(3)

        expected_total =
          a1.reload.total_sent_sats +
          a2.reload.total_sent_sats +
          a3.reload.total_sent_sats

        expect(cluster.cluster_profile.total_sent_sats).to eq(expected_total)
      end
    end

    context "when a transaction connects two existing clusters" do
      let(:blockhash_100) { "blockhash-100" }
      let(:blockhash_101) { "blockhash-101" }
      let(:blockhash_102) { "blockhash-102" }

      let(:tx_cluster_a) do
        {
          "txid" => "tx-a",
          "vin" => [
            {
              "prevout" => {
                "value" => "1.0",
                "scriptPubKey" => { "address" => "bc1qmerge111111111111111111111111111111111111" }
              }
            },
            {
              "prevout" => {
                "value" => "1.0",
                "scriptPubKey" => { "address" => "bc1qmerge222222222222222222222222222222222222" }
              }
            }
          ]
        }
      end

      let(:tx_cluster_b) do
        {
          "txid" => "tx-b",
          "vin" => [
            {
              "prevout" => {
                "value" => "2.0",
                "scriptPubKey" => { "address" => "bc1qmerge333333333333333333333333333333333333" }
              }
            },
            {
              "prevout" => {
                "value" => "2.0",
                "scriptPubKey" => { "address" => "bc1qmerge444444444444444444444444444444444444" }
              }
            }
          ]
        }
      end

      let(:tx_merge) do
        {
          "txid" => "tx-merge",
          "vin" => [
            {
              "prevout" => {
                "value" => "0.1",
                "scriptPubKey" => { "address" => "bc1qmerge111111111111111111111111111111111111" }
              }
            },
            {
              "prevout" => {
                "value" => "0.2",
                "scriptPubKey" => { "address" => "bc1qmerge333333333333333333333333333333333333" }
              }
            }
          ]
        }
      end

      before do
        allow(rpc).to receive(:getblockcount).and_return(102)

        allow(rpc).to receive(:getblockhash).with(100).and_return(blockhash_100)
        allow(rpc).to receive(:getblockhash).with(101).and_return(blockhash_101)
        allow(rpc).to receive(:getblockhash).with(102).and_return(blockhash_102)

        allow(rpc).to receive(:getblock).with(blockhash_100, 3).and_return({ "tx" => [tx_cluster_a] })
        allow(rpc).to receive(:getblock).with(blockhash_101, 3).and_return({ "tx" => [tx_cluster_b] })
        allow(rpc).to receive(:getblock).with(blockhash_102, 3).and_return({ "tx" => [tx_merge] })
      end

      it "merges the two clusters into one and rebuilds derived data" do
        result = described_class.call(from_height: 100, to_height: 102, rpc: rpc)

        expect(result[:clusters_created]).to eq(2)
        expect(result[:clusters_merged]).to eq(1)

        addresses = Address.where(
          address: [
            "bc1qmerge111111111111111111111111111111111111",
            "bc1qmerge222222222222222222222222222222222222",
            "bc1qmerge333333333333333333333333333333333333",
            "bc1qmerge444444444444444444444444444444444444"
          ]
        )

        cluster_ids = addresses.pluck(:cluster_id).uniq
        expect(cluster_ids.size).to eq(1)

        cluster = Cluster.find(cluster_ids.first)
        profile = cluster.cluster_profile

        expect(profile).to be_present
        expect(profile.cluster_size).to eq(4)
        expect(profile.total_sent_sats).to eq(addresses.sum(:total_sent_sats))
      end
    end
  end
end