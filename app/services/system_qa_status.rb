# frozen_string_literal: true

class SystemQaStatus
  Item = Struct.new(
    :key,
    :label,
    :status,
    :coverage,
    :command,
    keyword_init: true
  )

  GROUPS = [
    {
      key: "cluster_services",
      title: "Cluster — Services",
      items: [
        Item.new(
          key: "cluster_aggregator",
          label: "ClusterAggregator",
          status: :green,
          coverage: "Agrégation, cohérence, idempotence",
          command: "bundle exec rspec spec/services/cluster_aggregator_spec.rb"
        ),
        Item.new(
          key: "cluster_metrics_builder",
          label: "ClusterMetricsBuilder",
          status: :green,
          coverage: "Projection 24h/7j, activity_score, idempotence",
          command: "bundle exec rspec spec/services/cluster_metrics_builder_spec.rb"
        ),
        Item.new(
          key: "cluster_signal_engine",
          label: "ClusterSignalEngine",
          status: :green,
          coverage: "Signaux simples, anti-bruit, idempotence",
          command: "bundle exec rspec spec/services/cluster_signal_engine_spec.rb"
        ),
        Item.new(
          key: "cluster_scanner",
          label: "ClusterScanner",
          status: :orange,
          coverage: "Validation manuelle OK, pas encore couvert en RSpec",
          command: nil
        )
      ]
    },
    {
      key: "cluster_ui",
      title: "Cluster — UI",
      items: [
        Item.new(
          key: "address_lookup",
          label: "AddressLookup",
          status: :green,
          coverage: "Rendu page adresse, classification, score, signaux, synthèse",
          command: "bundle exec rspec spec/requests/address_lookup_spec.rb"
        ),
        Item.new(
          key: "address_lookup_edge_cases",
          label: "AddressLookup edge cases",
          status: :green,
          coverage: "Adresse non observée, sans signaux, cluster incomplet",
          command: "bundle exec rspec spec/requests/address_lookup_edge_cases_spec.rb"
        ),
        Item.new(
          key: "cluster_signals_pages",
          label: "ClusterSignals pages",
          status: :green,
          coverage: "/cluster_signals, /top, filtres, tri, ranking",
          command: "bundle exec rspec spec/requests/cluster_signals_spec.rb"
        ),
        Item.new(
          key: "system_page",
          label: "/system",
          status: :orange,
          coverage: "Validation visuelle OK, pas encore de request specs",
          command: nil
        )
      ]
    },
    {
      key: "cluster_ops",
      title: "Cluster — Ops / Pipeline",
      items: [
        Item.new(
          key: "v3_rake_tasks",
          label: "Tâches rake V3",
          status: :gray,
          coverage: "À normaliser / finaliser",
          command: nil
        ),
        Item.new(
          key: "v3_cron",
          label: "Cron V3",
          status: :gray,
          coverage: "À implémenter",
          command: nil
        ),
        Item.new(
          key: "ui_metrics_v3",
          label: "UI metrics V3",
          status: :gray,
          coverage: "tx_24h / 7d, sent_24h / 7d, activity_score non affichés",
          command: nil
        )
      ]
    }
  ].freeze

  def self.groups
    GROUPS
  end

  def self.summary
    items = GROUPS.flat_map { |g| g[:items] }

    {
      green: items.count { |i| i.status == :green },
      orange: items.count { |i| i.status == :orange },
      gray: items.count { |i| i.status == :gray },
      total: items.size
    }
  end
end