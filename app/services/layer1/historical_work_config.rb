# frozen_string_literal: true

module Layer1
  module HistoricalWorkConfig
    DEFAULT_MAX_LAYER1_LAG_BLOCKS = 6
    # Le runtime development observé le 2026-07-03 oscille normalement
    # autour de 6 à 9 blocs de retard Cluster pendant que Layer1 suit le tip.
    # Un budget à 3 affame les projections historiques sans protéger mieux
    # la chaîne stricte ; 12 laisse une marge courte sans masquer un décrochage.
    DEFAULT_MAX_CLUSTER_LAG_BLOCKS = 12
    MAX_CONFIGURED_LAG_BLOCKS = 100

    module_function

    def max_layer1_lag_blocks
      bounded_integer(
        "HISTORICAL_MAX_LAYER1_LAG_BLOCKS",
        DEFAULT_MAX_LAYER1_LAG_BLOCKS
      )
    end

    def max_cluster_lag_blocks
      bounded_integer(
        "HISTORICAL_MAX_CLUSTER_LAG_BLOCKS",
        DEFAULT_MAX_CLUSTER_LAG_BLOCKS
      )
    end

    def bounded_integer(name, default)
      value =
        Integer(
          ENV.fetch(name, default.to_s),
          10
        )

      [
        [value, 0].max,
        MAX_CONFIGURED_LAG_BLOCKS
      ].min
    rescue ArgumentError, TypeError
      default
    end
  end
end
