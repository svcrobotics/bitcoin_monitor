# frozen_string_literal: true

require "pp"

cases = [
  {
    source_cluster_id: 311_253,
    downstream_cluster_id: 39_960,
    window_from_height: 956_388,
    window_to_height: 956_887,

    deposit_evidence: {
      address_count: 1_484,
      inflow_count: 1_505,
      outflow_count: 15,
      balance_btc: "0.00131007",
      total_received_btc: "0.61803407",
      total_sent_btc: "0.616724"
    },

    sweep_evidence: {
      consolidation_transactions: 15,
      consolidation_blocks: 15,
      top_destination_cluster_id: 39_960,
      top_destination_share_percent: "100",
      destination_spending_transactions: 2_248,
      destination_spending_blocks: 1_435
    },

    distribution_evidence: {
      spending_transactions: 428,
      spending_blocks: 264,
      mixed_input_transactions: 2,
      missing_output_transactions: 0,
      average_outputs_per_transaction: "7.39",
      median_outputs_per_transaction: "7",
      p90_outputs_per_transaction: "11",
      batch_transactions: 362,
      batch_transaction_percent: "84.58",
      distinct_external_addresses: 2_449,
      distinct_external_clusters: 285,
      total_external_btc: "86.95068969",
      unclustered_external_percent: "33.56",
      top_destination_share_percent: "30.86"
    },

    provenance: {
      mode:
        "read_only_canary_audit",

      audit_version:
        "downstream_wallet_distribution_v2",

      audited_at:
        "2026-07-06",

      source:
        "strict_layer1_utxo_outputs_and_cluster_inputs"
    }
  },

  {
    source_cluster_id: 846_935,
    downstream_cluster_id: 130_448,
    window_from_height: 956_389,
    window_to_height: 956_888,

    deposit_evidence: {
      address_count: 1_667,
      inflow_count: 1_651,
      outflow_count: 3,
      balance_btc: "0",
      total_received_btc: "1.15303059",
      total_sent_btc: "1.15303059"
    },

    sweep_evidence: {
      consolidation_transactions: 3,
      consolidation_blocks: 3,
      top_destination_cluster_id: 130_448,
      top_destination_share_percent: "99.13",
      destination_spending_transactions: 277,
      destination_spending_blocks: 264
    },

    distribution_evidence: {
      spending_transactions: 50,
      spending_blocks: 45,
      mixed_input_transactions: 0,
      missing_output_transactions: 0,
      average_outputs_per_transaction: "274.52",
      median_outputs_per_transaction: "284.5",
      p90_outputs_per_transaction: "344.3",
      batch_transactions: 48,
      batch_transaction_percent: "96",
      distinct_external_addresses: 10_441,
      distinct_external_clusters: 352,
      total_external_btc: "428.04715004",
      unclustered_external_percent: "29.01",
      top_destination_share_percent: "3.06"
    },

    provenance: {
      mode:
        "read_only_canary_audit",

      audit_version:
        "downstream_wallet_distribution_v2",

      audited_at:
        "2026-07-06",

      source:
        "strict_layer1_utxo_outputs_and_cluster_inputs"
    }
  }
]

results =
  cases.map do |attributes|
    ActorBehaviors::Heavy::BuildFromEvidence.call(
      **attributes
    )
  end

pp(results)
