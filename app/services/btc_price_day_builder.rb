# frozen_string_literal: true

# app/services/btc_price_day_builder.rb
class BtcPriceDayBuilder
  SOURCES = {
    kraken:   PriceSources::KrakenDaily.new,
    coinbase: PriceSources::CoinbaseDaily.new,
    bitstamp: PriceSources::BitstampDaily.new
  }.freeze

  def self.call(day:)
    new(day: day).call
  end

  def initialize(day:)
    @day = day
  end

  def call
    samples = fetch_samples

    good = samples.values.select do |h|
      h.is_a?(Hash) && get(h, :close).present?
    end

    raise "Aucune source de prix disponible pour #{@day} samples=#{samples.inspect}" if good.empty?

    row = BtcPriceDay.find_or_initialize_by(day: @day)

    opens   = good.map { |x| get(x, :open) }
    highs   = good.map { |x| get(x, :high) }
    lows    = good.map { |x| get(x, :low) }
    closes  = good.map { |x| get(x, :close) }
    volumes = good.map { |x| get(x, :volume_btc) }.compact

    row.open_usd   = median(opens)
    row.high_usd   = median(highs)
    row.low_usd    = median(lows)
    row.close_usd  = median(closes)
    row.volume_btc = median(volumes)

    # Garde-fou ABSOLU : évite le NOT NULL violation sur close_usd
    if row.close_usd.blank?
      raise "close_usd nil for #{@day} closes=#{closes.inspect} good=#{good.inspect} samples=#{samples.inspect}"
    end

    # ---- EUR SAFE (ne pas écraser si déjà présent) ----
    apply_eur_safe!(row)

    row.source = "composite"
    row.sources_json = samples if row.respond_to?(:sources_json=)
    row.computed_at  = Time.current if row.respond_to?(:computed_at=)

    row.save!
    row
  end

  private

  def fetch_samples
    samples = {}

    SOURCES.each do |name, client|
      v = client.fetch_day(@day)

      # Normaliser les clés si c'est un hash (accepte string/symbol)
      samples[name] =
        if v.is_a?(Hash)
          v.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
        else
          v
        end
    rescue => e
      samples[name] = { error: e.message }
    end

    samples
  end

  # Lit :close ou "close" (sécurité si une source renvoie des clés string)
  def get(h, key)
    return nil unless h.is_a?(Hash)
    h[key] || h[key.to_s]
  end

  # EURUSD = 1 EUR = X USD  =>  USD->EUR : usd / eurusd
  # SAFE = ne remplit que les champs EUR manquants
  def apply_eur_safe!(row)
    # Si on n'a même pas d'USD, inutile
    return if row.close_usd.blank? && row.open_usd.blank? && row.high_usd.blank? && row.low_usd.blank?

    eurusd = eurusd_rate_for(@day)
    return if eurusd.blank?

    rate = eurusd.to_d
    return if rate <= 0

    # Remplir seulement si champ EUR vide
    if row.open_eur.blank? && row.open_usd.present?
      row.open_eur = (row.open_usd.to_d / rate).round(8)
    end

    if row.high_eur.blank? && row.high_usd.present?
      row.high_eur = (row.high_usd.to_d / rate).round(8)
    end

    if row.low_eur.blank? && row.low_usd.present?
      row.low_eur = (row.low_usd.to_d / rate).round(8)
    end

    if row.close_eur.blank? && row.close_usd.present?
      row.close_eur = (row.close_usd.to_d / rate).round(8)
    end
  end

  # Priorité : FX du jour -> fallback ENV (stable)
  def eurusd_rate_for(day)
    fx =
      begin
        FxSources::EurUsdDaily.fetch_close(day)
      rescue => e
        Rails.logger.warn("[FX] EurUsdDaily failed for #{day}: #{e.class} #{e.message}")
        nil
      end

    return fx if fx.present?

    Rails.logger.warn("[FX] fallback EURUSD_RATE used for #{day}")
    ENV.fetch("EURUSD_RATE", "1.09").to_d
  end

  def median(values)
    arr = Array(values).compact.map(&:to_d).sort
    return nil if arr.empty?

    mid = arr.length / 2
    arr.length.odd? ? arr[mid] : ((arr[mid - 1] + arr[mid]) / 2)
  end
end
