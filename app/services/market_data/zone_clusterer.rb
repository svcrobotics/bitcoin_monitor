# app/services/market_data/zone_clusterer.rb
module MarketData
  class ZoneClusterer
    Cluster = Struct.new(:kind, :center, :low, :high, :touches, keyword_init: true)

    def initialize(tolerance_pct: 0.012)
      @tol = tolerance_pct.to_d
    end

    # pivots: array d'objets avec #price (Decimal) et #day
    # kind: "support" | "resistance"
    # Retourne: [Cluster...]
    def call(pivots:, kind:)
      pivots = Array(pivots)
      return [] if pivots.empty?

      # On trie par prix pour faire un clustering simple 1D
      sorted = pivots.sort_by { |p| p.price.to_d }

      clusters = []
      current = []

      sorted.each do |p|
        if current.empty?
          current << p
          next
        end

        center = median_price(current)

        if within_tolerance?(p.price.to_d, center)
          current << p
        else
          clusters << build_cluster(current, kind)
          current = [p]
        end
      end

      clusters << build_cluster(current, kind) if current.any?
      clusters
    end

    private

    def within_tolerance?(price, center)
      # |price-center| / center <= tol
      return false if center.zero?
      ((price - center).abs / center) <= @tol
    end

    def median_price(pivots)
      arr = pivots.map { |p| p.price.to_d }.sort
      mid = arr.size / 2
      arr.size.odd? ? arr[mid] : ((arr[mid - 1] + arr[mid]) / 2)
    end

    def build_cluster(pivots, kind)
      prices = pivots.map { |p| p.price.to_d }.sort
      center = median_price(pivots)

      Cluster.new(
        kind: kind,
        center: center,
        low: prices.first,
        high: prices.last,
        touches: pivots
      )
    end
  end
end
