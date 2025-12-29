# lib/tasks/brc20.rake
namespace :brc20 do
  # =========================================================
  # Patch global pour éviter "string contains null byte"
  # =========================================================
  def patch_null_byte_escape!
    conn = ActiveRecord::Base.connection

    # Patch de la méthode `escape` si elle existe
    if conn.respond_to?(:escape) && !conn.respond_to?(:escape_without_null_sanitization)
      class << conn
        alias_method :escape_without_null_sanitization, :escape

        def escape(str)
          return escape_without_null_sanitization(str) if str.nil?

          sanitized = str.to_s.delete("\x00")
          escape_without_null_sanitization(sanitized)
        end
      end
    end

    # Certains adapters utilisent `quote_string` au lieu de `escape`
    if conn.respond_to?(:quote_string) && !conn.respond_to?(:quote_string_without_null_sanitization)
      class << conn
        alias_method :quote_string_without_null_sanitization, :quote_string

        def quote_string(str)
          return quote_string_without_null_sanitization(str) if str.nil?

          sanitized = str.to_s.delete("\x00")
          quote_string_without_null_sanitization(sanitized)
        end
      end
    end
  end

  # ===========================
  # Scan manuel d'une plage
  # ===========================
  desc "Scan BRC-20 events in a given block range"
  task :scan, [:from, :to] => :environment do |t, args|
    from = args[:from].to_i
    to   = args[:to].to_i

    if from <= 0 || to <= 0 || to < from
      abort "Usage: bin/rails brc20:scan[FROM,TO]"
    end

    # 🔒 Patch anti-null-byte pour ce run
    patch_null_byte_escape!

    rpc = BitcoinRpc.new

    puts "Scanning BRC-20 from block #{from} to #{to}..."
    Brc20Indexer.new(rpc: rpc, from_height: from, to_height: to).run
    puts "Done."
  end

  # ===========================
  # Sync par petits paquets (pour tests / manuel)
  # ===========================
  desc "Synchronise les BRC-20 depuis la dernière hauteur indexée jusqu'au tip (par paquets)"
  task :sync_batch => :environment do
    # 🔒 Patch anti-null-byte
    patch_null_byte_escape!

    rpc = BitcoinRpc.new

    tip_height  = rpc.get_block_count.to_i
    max_indexed = Brc20BlockStat.maximum(:block_height)

    from_height =
      if max_indexed
        max_indexed + 1
      else
        [tip_height - 2016, 0].max
      end

    if from_height > tip_height
      puts "[brc20:sync_batch] Rien à faire, déjà à jour (from=#{from_height}, tip=#{tip_height})"
      next
    end

    batch_size = 500
    to_height  = [from_height + batch_size - 1, tip_height].min

    puts "[brc20:sync_batch] Synchronisation BRC-20 de #{from_height} à #{to_height} (tip=#{tip_height})"

    Brc20Indexer.new(
      rpc:         rpc,
      from_height: from_height,
      to_height:   to_height
    ).run

    puts "[brc20:sync_batch] Terminé."
  end

  # ===========================
  # Sync "classique" jusqu'au tip (une seule fois)
  # ===========================
  desc "Synchronise BRC-20 depuis le dernier bloc indexé jusqu'au tip (en un seul scan)"
  task :sync => :environment do
    # 🔒 Patch anti-null-byte
    patch_null_byte_escape!

    rpc = BitcoinRpc.new

    tip  = rpc.get_block_count.to_i
    last = Brc20BlockStat.maximum(:block_height).to_i
    from = last + 1

    puts "[brc20:sync] Synchronisation BRC-20 de #{from} à #{tip} (tip=#{tip})"

    if from <= tip
      Brc20Indexer.new(
        rpc:         rpc,
        from_height: from,
        to_height:   tip
      ).run
    else
      puts "[brc20:sync] Rien à faire, déjà à jour."
    end

    # On enregistre l'heure du dernier sync (utilisée dans le dashboard)
    File.write(
      Rails.root.join("tmp/brc20_last_run"),
      Time.current.to_s
    )

    puts "[brc20:sync] Terminé."
  end

  # ===========================
  # Recalcul des holders
  # ===========================
  desc "Recalculer holders_count à partir de brc20_balances"
  task :recompute_holders => :environment do
    puts "🔁 Reset holders_count..."
    Brc20Token.update_all(holders_count: 0)

    puts "🧮 Calcul des holders non nuls..."
    counts = Brc20Balance
      .where.not(balance: "0")
      .group(:brc20_token_id)
      .count

    counts.each do |token_id, count|
      Brc20Token.where(id: token_id).update_all(holders_count: count)
    end

    puts "✅ holders_count recalculés."
  end

  # ===========================
  # Full rescan propre
  # ===========================
  desc "Full rescan BRC-20 sur la plage [779966..925753]"
  task :full_rescan => :environment do
    # 🔒 Patch anti-null-byte
    patch_null_byte_escape!

    puts "🧹 Nettoyage des tables dérivées BRC-20..."
    Brc20Balance.delete_all
    Brc20Event.delete_all
    Brc20BlockStat.delete_all
    Brc20TokenDailyStat.delete_all

    # IMPORTANT : on reset aussi les compteurs des tokens
    puts "🧹 Reset des compteurs sur brc20_tokens..."
    Brc20Token.update_all(
      total_minted:      "0",
      total_transferred: "0",
      holders_count:     0,
      events_count:      0
    )

    puts "✅ Tables nettoyées."

    # 🚀 Désactivation du logging Rails & SQL pour accélérer
    Rails.logger = Logger.new(nil)
    ActiveRecord::Base.logger = nil

    to = 926_737
    from = 922_417

    puts "🚀 Rescan BRC-20 de #{from} à #{to}..."

    indexer = Brc20Indexer.new(
      rpc:         BitcoinRpc.new,
      from_height: from,
      to_height:   to,
      full_rescan: true
    )
    indexer.run

    # Optionnel : enregistrer un "last_run" après un full rescan
    File.write(
      Rails.root.join("tmp/brc20_last_run"),
      Time.current.to_s
    )

    puts "✅ Full rescan terminé."
  end
end
