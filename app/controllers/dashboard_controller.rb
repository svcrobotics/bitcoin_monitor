class DashboardController < ApplicationController
  def index
    rpc = BitcoinRpc.new

    # === Infos Bitcoin de base ===
    @blockchain = rpc.get_blockchain_info
    @mempool    = rpc.mempool_info

    minfee     = @mempool["mempoolminfee"].to_f
    @min_sat_vb = (minfee * 100_000_000 / 1000).round

    @mempool_security = MempoolSecurityAnalyzer.new(@mempool, min_sat_vb: @min_sat_vb).call

    explorer       = BlockExplorer.new(rpc)
    @recent_blocks = explorer.recent_blocks(50) # tu pourras l’utiliser plus tard si tu veux

    # === Résumé BRC-20 (juste pour le dashboard) ===
    coverage_from = 920_000   # bloc de départ (comme avant)
    coverage_to   = 926_028   # bloc de fin   (comme avant)

    coverage_service   = Brc20ScanCoverage.new(
      target_from: coverage_from,
      target_to:   coverage_to
    )
    @brc20_scan_stats = coverage_service.stats
    @brc20_scan_done  = (@brc20_scan_stats[:missing_blocks].zero?)

    # Dernière exécution du cron BRC-20 (affichée en petit sur le dashboard)
    load_brc20_cron_status

    # === Lightning : état du nœud LN (optionnel si LND est configuré) ===
    @lightning_status = LightningStatus.new.call

    @monitoring_rules = MonitoringRuleEngine.new(
      blockchain:       @blockchain,
      mempool:          @mempool,
      mempool_security: @mempool_security,
      lightning_status: @lightning_status,
      brc20_scan_stats: @brc20_scan_stats
    ).call

  rescue => e
    @error = e.message
    @blockchain         = nil
    @mempool            = nil
    @recent_blocks      = []
    @brc20_scan_stats   = nil
    @brc20_scan_done    = false
    @brc20_last_sync_run = nil
    @lightning_status  = { enabled: false, error: "Erreur Bitcoin RPC, Lightning non évalué" }
    @monitoring_rules  = []
  end

  private

  def load_brc20_cron_status
    file = Rails.root.join("tmp/brc20_last_run")

    if File.exist?(file)
      @brc20_last_sync_run = Time.parse(File.read(file)) rescue nil
    else
      @brc20_last_sync_run = nil
    end
  end
end
