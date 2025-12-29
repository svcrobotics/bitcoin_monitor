# app/services/mempool_security_analyzer.rb
class MempoolSecurityAnalyzer
  # mempool_info = hash renvoyé par Bitcoin Core (getmempoolinfo)
  # min_sat_vb   = frais minimum (en sat/vB) pour entrer dans la mempool
  def initialize(mempool_info, min_sat_vb:)
    @mempool = mempool_info || {}
    @min_sat_vb = min_sat_vb.to_i
  end

  def call
    bytes    = @mempool["bytes"].to_i
    tx_count = @mempool["size"].to_i

    mem_mb = bytes / 1_000_000.0

    level, label, color = compute_level(mem_mb, @min_sat_vb, tx_count)

    {
      level: level,           # :low, :medium, :high, :critical
      label: label,           # "Faible", "Élevé", etc.
      color: color,           # "green", "yellow", "red", etc.
      mem_mb: mem_mb.round(2),
      tx_count: tx_count,
      min_sat_vb: @min_sat_vb,
      summary: summary(level, mem_mb, @min_sat_vb, tx_count),
      advice: advice(level)
    }
  end

  private

  def compute_level(mem_mb, min_sat_vb, tx_count)
    # Tu pourras ajuster ces seuils avec le temps, c’est une V1.
    if mem_mb < 5 && min_sat_vb < 3
      [:low, "Charge faible", :green]
    elsif mem_mb < 20 && min_sat_vb < 15
      [:medium, "Charge modérée", :yellow]
    elsif mem_mb < 50 || min_sat_vb < 50
      [:high, "Réseau sous tension", :orange]
    else
      [:critical, "Réseau congestionné", :red]
    end
  end

  def summary(level, mem_mb, min_sat_vb, tx_count)
    case level
    when :low
      "La mempool est peu chargée (~#{mem_mb.round(1)} MB, #{tx_count} transactions, min ~#{min_sat_vb} sat/vB). Le réseau est fluide."
    when :medium
      "La mempool est modérément chargée (~#{mem_mb.round(1)} MB, #{tx_count} transactions, min ~#{min_sat_vb} sat/vB). Les frais montent progressivement."
    when :high
      "La mempool est fortement chargée (~#{mem_mb.round(1)} MB, #{tx_count} transactions, min ~#{min_sat_vb} sat/vB). Les confirmations peuvent être lentes sans frais élevés."
    when :critical
      "La mempool est en situation de congestion sévère (> #{mem_mb.round(1)} MB, min ~#{min_sat_vb} sat/vB). Le réseau est saturé."
    else
      "État de la mempool indéterminé."
    end
  end

  def advice(level)
    case level
    when :low
      "Vous pouvez utiliser des frais très bas sans risque particulier. Idéal pour des transactions non urgentes."
    when :medium
      "Évitez les frais trop bas. Utilisez des frais moyens si vous souhaitez une confirmation dans un délai raisonnable."
    when :high
      "Pour des paiements importants ou urgents, utilisez des frais élevés. Pour les montants faibles, envisagez Lightning."
    when :critical
      "Différez les transactions non urgentes. Pour les paiements sensibles, privilégiez Lightning ou attendez que la mempool se vide."
    else
      "Surveillez l’évolution de la mempool avant d’envoyer des montants importants."
    end
  end
end
