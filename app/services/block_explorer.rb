# app/services/block_explorer.rb
class BlockExplorer
  def initialize(rpc = BitcoinRpc.new)
    @rpc = rpc
  end

  # Retourne un tableau de hachages pour les N derniers blocs
  def recent_blocks(limit = 10)
    tip_height = @rpc.best_block_height

    (0...limit).map do |i|
      height = tip_height - i
      stats  = @rpc.getblockstats(height)

      {
        "height"         => height,
        "hash"           => stats["blockhash"],
        "time"           => Time.at(stats["time"]).utc,
        "txs"            => stats["txs"],
        "total_size"     => stats["total_size"],      # bytes
        "total_weight"   => stats["total_weight"],    # weight units
        "totalfee"       => stats["totalfee"],        # en satoshis
        "avgfeerate"     => stats["avgfeerate"],      # sat/vB
        "medianfee"      => stats["medianfee"],       # sat
        "swtxs"          => stats["swtxs"],           # tx SegWit
        "utxo_increase"  => stats["utxo_increase"],   # UTXO créés - consommés
        "utxo_size_inc"  => stats["utxo_size_inc"],   # taille UTXO
        "fill_percent"   => (stats["total_weight"].to_f / 4_000_000 * 100).round(2)
      }
    end
  end
end
