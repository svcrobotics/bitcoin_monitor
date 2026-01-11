# frozen_string_literal: true

# app/services/exchange_true_flow_rebuilder.rb
#
# 🔁 Recalcul de la série "True Exchange Flow" (inflow / outflow / netflow) utilisée par le dashboard
#
# OBJECTIF
# --------
# Ce service reconstruit, jour par jour, une estimation on-chain des flux d'exchanges :
# - Inflow  : BTC qui entrent dans le set d'adresses "exchange" (dépôts => pression vendeuse potentielle)
# - Outflow : BTC qui sortent du set d'adresses "exchange" (retraits => réduction de liquidité vendeuse)
# - Netflow : Inflow - Outflow (positif = les exchanges reçoivent net, négatif = les exchanges se vident net)
#
# IDÉE CLÉ (POURQUOI "TRUE")
# -------------------------
# Contrairement à une simple somme de volumes "exchange-like", on essaye ici de classer
# chaque transaction en "dépôt" ou "retrait" en regardant :
# - si la transaction dépense (en entrée) une adresse exchange (source exchange => retrait probable)
# - et/ou si elle paie (en sortie) une adresse exchange (destination exchange => dépôt probable)
#
# Concrètement :
# - Dépôt (monde -> exchange) : des outputs vont vers des adresses exchange,
#   et les inputs ne viennent pas d'un exchange (heuristique "input_exchange" = false)
# - Retrait (exchange -> monde) : au moins un input vient d'un exchange,
#   et on compte les outputs qui vont vers des adresses NON-exchange
#
# ÉTAPES DE CE SERVICE
# --------------------
# 1) Construction du set "exchange_set" à partir du modèle ExchangeAddress
#    (auto-détecté en amont, filtré par nombre d'occurrences minimum).
# 2) Parcours d'une plage de dates et calcul inflow/outflow/netflow pour chaque jour.
# 3) Calcul des baselines (moyennes 7j/30j/200j) puis calcul ratio et statut (green/amber/red).
#
# HYPOTHÈSES / LIMITES
# --------------------
# - C'est une estimation : on ne prétend pas connaître "la vérité parfaite".
# - On ne prend que des WhaleAlert considérées suffisamment "exchange-like" (exchange_likelihood >= EX_MIN).
# - On dépend de Bitcoin Core RPC pour décoder les tx et parfois dériver une adresse via un descriptor (deriveaddresses).
# - Les exchanges font des mouvements internes, du batching, des consolidations : certaines tx peuvent être ambiguës.
# - Performance : on cache les transactions (tx_cache) pendant l'exécution pour éviter des appels RPC redondants.
#
class ExchangeTrueFlowRebuilder
  # Fenêtres (en jours) utilisées pour calculer des moyennes glissantes d'inflow.
  WINDOWS = [7, 30, 200].freeze

  # Seuil minimal de "probabilité exchange" pour inclure une WhaleAlert dans le calcul.
  # Plus ce seuil est haut, plus on réduit le bruit… mais plus on risque de rater des événements.
  EX_MIN  = 70

  # Point d'entrée principal (convention Rails).
  #
  # @param days_back [Integer] nombre de jours à recalculer dans le passé
  #
  # Exemple :
  #   ExchangeTrueFlowRebuilder.call(days_back: 220)
  #
  def self.call(days_back: 220)
    new(days_back: days_back).call
  end

  # Initialise le service.
  #
  # @param days_back [Integer] nombre de jours à recalculer
  #
  # Effets :
  # - crée un client BitcoinRpc (connexion au node)
  # - crée un cache mémoire @tx_cache pour éviter de refetch les mêmes txid
  #
  def initialize(days_back:)
    @days_back = days_back
    @rpc = BitcoinRpc.new
    @tx_cache = {}
  end

  # Exécute le recalcul complet.
  #
  # Étapes détaillées :
  # 1) Récupère le seuil d'occurrences minimal via ENV["EXCHANGE_ADDR_MIN_OCC"] (défaut 8).
  # 2) Construit le set d'adresses exchange à partir de ExchangeAddress (occurrences >= seuil).
  # 3) Pour chaque jour de la période :
  #    - calcule inflow/outflow via compute_day
  #    - calcule netflow = inflow - outflow
  #    - sauvegarde (ou met à jour) la ligne ExchangeTrueFlow du jour
  # 4) Recalcule ensuite les baselines et les statuts (green/amber/red) pour toute la série.
  #
  # Pourquoi un seuil d'occurrences ?
  # - une adresse vue 1 fois n'est pas fiable (risque de faux positif)
  # - une adresse vue >= 8 fois a une probabilité plus forte d'être un wallet d'exchange
  #
  # @return [void]
  def call
    threshold = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_OCC", "8"))
    exchange_set = ExchangeAddress.where("occurrences >= ?", threshold).pluck(:address).to_set

    range = (@days_back.days.ago.to_date)..Date.current
    range.each do |day|
      inflow, outflow = compute_day(day, exchange_set)
      netflow = inflow - outflow

      row = ExchangeTrueFlow.find_or_initialize_by(day: day)
      row.inflow_btc  = inflow
      row.outflow_btc = outflow
      row.netflow_btc = netflow
      row.save!
    end

    compute_baselines_and_status!
  end

  private

  # Calcule l'inflow et l'outflow pour une journée donnée.
  #
  # Fenêtre :
  # - du début du jour (00:00:00) à la fin du jour (23:59:59)
  #
  # Source de données :
  # - WhaleAlert sur cette fenêtre
  # - filtre : exchange_likelihood >= EX_MIN
  #
  # Pipeline par alerte :
  # 1) Récupère la transaction brute (tx) via RPC (avec cache)
  # 2) Détecte si au moins un input vient d'une adresse exchange (input_exchange?)
  # 3) Additionne les outputs vers exchange (ex_out) et vers non-exchange (non_ex_out)
  # 4) Classement :
  #    - si input_exchange? == true  => retrait probable (exchange -> monde) => outflow += non_ex_out
  #    - sinon                      => dépôt probable (monde -> exchange)   => inflow += ex_out
  #
  # Pourquoi ce classement ?
  # - Si l'exchange dépense un UTXO (input), il initie souvent un retrait (withdrawal) ou une distribution.
  # - Si aucun input n'est exchange, mais des outputs payent un exchange, cela ressemble à un dépôt.
  #
  # Limites :
  # - batching / coinjoin / mouvements internes peuvent créer des cas ambigus
  # - on ignore OP_RETURN (nulldata) car ce n'est pas une sortie monétaire exploitable
  #
  # @param day [Date]
  # @param exchange_set [Set<String>] set des adresses considérées exchange
  # @return [Array<BigDecimal, BigDecimal>] [inflow_btc, outflow_btc]
  def compute_day(day, exchange_set)
    start_t = day.beginning_of_day
    end_t   = day.end_of_day

    alerts = WhaleAlert
      .where("block_time BETWEEN ? AND ?", start_t, end_t)
      .where("exchange_likelihood >= ?", EX_MIN)

    inflow  = 0.to_d
    outflow = 0.to_d

    alerts.find_each do |a|
      tx = fetch_tx(a.txid, a.block_height)
      next if tx.blank?

      input_exchange = any_input_exchange?(tx, exchange_set)
      ex_out, non_ex_out = sum_outputs_by_exchange(tx, exchange_set)

      if input_exchange
        # exchange -> monde : on ne compte comme outflow que ce qui sort vers des NON-exchange
        outflow += non_ex_out
      else
        # monde -> exchange : on compte comme inflow ce qui arrive sur des adresses exchange
        inflow += ex_out
      end
    rescue BitcoinRpc::Error
      # Si une tx ou un appel RPC foire, on saute l'alerte et on continue
      next
    end

    [inflow, outflow]
  end

  # Récupère une transaction décodée via Bitcoin Core RPC, avec cache mémoire.
  #
  # Stratégie :
  # - Si txid est déjà en cache : on retourne immédiatement.
  # - Si block_height est fourni :
  #   - on résout le blockhash
  #   - on appelle getrawtransaction(txid, true, blockhash)
  # - En cas d'erreur, fallback :
  #   - getrawtransaction(txid, true, nil)
  #
  # Pourquoi blockhash ?
  # - selon la configuration du node, fournir le blockhash peut améliorer la robustesse
  #   (et parfois la performance).
  #
  # Note technique :
  # - Pour reconstruire les prevouts (inputs), il faut pouvoir refetch les tx précédentes :
  #   l'idéal est un node avec txindex actif (ou une stratégie alternative).
  #
  # @param txid [String]
  # @param block_height [Integer, nil]
  # @return [Hash, nil] transaction décodée
  def fetch_tx(txid, block_height = nil)
    return @tx_cache[txid] if @tx_cache.key?(txid)

    blockhash = (block_height.present? ? @rpc.getblockhash(block_height) : nil)
    tx = @rpc.getrawtransaction(txid, true, blockhash)
    @tx_cache[txid] = tx
  rescue BitcoinRpc::Error
    tx = @rpc.getrawtransaction(txid, true, nil)
    @tx_cache[txid] = tx
  end

  # Détermine si la transaction dépense au moins un UTXO provenant d'une adresse exchange.
  #
  # Logique :
  # - Pour chaque vin (input) :
  #   - ignorer coinbase
  #   - fetch la transaction précédente (prev_txid)
  #   - récupérer l'adresse de la sortie dépensée (prev_vout)
  #   - si cette adresse est dans exchange_set => true
  #
  # Pourquoi "au moins un input" ?
  # - Heuristique simple et robuste pour estimer "la source" de la tx.
  # - Si un exchange fournit un input, il participe à la tx (souvent initiateur).
  #
  # Limites :
  # - coinjoin/mix, consolidations, batching ou tx partagées peuvent fausser l'interprétation.
  #
  # @param tx [Hash]
  # @param exchange_set [Set<String>]
  # @return [Boolean]
  def any_input_exchange?(tx, exchange_set)
    Array(tx["vin"]).any? do |vin|
      next false if vin["coinbase"].present?

      prev_txid = vin["txid"]
      prev_vout = vin["vout"]
      next false if prev_txid.blank? || prev_vout.nil?

      prev = fetch_tx(prev_txid) # txindex synced => ok (hypothèse de fonctionnement)
      addr = prevout_address(prev, prev_vout)
      addr.present? && exchange_set.include?(addr)
    end
  end

  # Extrait l'adresse associée à une sortie (vout) d'une transaction précédente.
  #
  # Étapes :
  # - retrouver la vout correspondant à l'index `vout_index` (champ "n")
  # - récupérer scriptPubKey
  # - convertir scriptPubKey -> adresse via scriptpubkey_address
  #
  # @param prev_tx [Hash]
  # @param vout_index [Integer]
  # @return [String, nil]
  def prevout_address(prev_tx, vout_index)
    vout = Array(prev_tx["vout"]).find { |x| x["n"].to_i == vout_index.to_i }
    spk  = vout && vout["scriptPubKey"]
    return nil if spk.blank?

    scriptpubkey_address(spk)
  rescue BitcoinRpc::Error
    nil
  end

  # Convertit une structure scriptPubKey en adresse (si possible).
  #
  # Tentatives (dans l'ordre) :
  # 1) spk["address"]
  # 2) spk["addresses"].first
  # 3) si absent : utiliser spk["desc"] et deriveaddresses(desc)
  #
  # Pourquoi deriveaddresses ?
  # - Bitcoin Core peut renvoyer un descriptor au lieu d'une adresse directe
  #   selon les types de scripts (segwit, taproot, etc.) et le format RPC.
  #
  # Limites :
  # - certains scripts peuvent rester non résolus (desc vide ou RPC error)
  #
  # @param spk [Hash]
  # @return [String, nil]
  def scriptpubkey_address(spk)
    addr = spk["address"] || Array(spk["addresses"]).first
    return addr if addr.present?

    desc = spk["desc"].to_s
    return nil if desc.blank?

    Array(@rpc.deriveaddresses(desc)).first
  rescue BitcoinRpc::Error
    nil
  end

  # Somme les outputs d'une transaction en deux compartiments :
  # - ex_sum     : total BTC envoyé vers des adresses exchange (addr ∈ exchange_set)
  # - non_ex_sum : total BTC envoyé vers des adresses non-exchange (tout le reste)
  #
  # Règles :
  # - ignore OP_RETURN (nulldata) : pas un transfert monétaire
  # - ignore values <= 0
  # - conversion BigDecimal pour éviter les erreurs de float
  #
  # Pourquoi cette séparation ?
  # - une même transaction peut payer plusieurs destinataires (batching)
  # - on veut compter uniquement la partie pertinente selon la classification dépôt/retrait
  #
  # @param tx [Hash]
  # @param exchange_set [Set<String>]
  # @return [Array<BigDecimal, BigDecimal>] [ex_sum, non_ex_sum]
  def sum_outputs_by_exchange(tx, exchange_set)
    ex_sum     = 0.to_d
    non_ex_sum = 0.to_d

    Array(tx["vout"]).each do |vout|
      val = begin
        BigDecimal(vout["value"].to_s)
      rescue
        0.to_d
      end
      next if val <= 0

      spk = vout["scriptPubKey"] || {}
      next if spk["type"].to_s == "nulldata" # OP_RETURN

      addr = scriptpubkey_address(spk)

      if addr.present? && exchange_set.include?(addr)
        ex_sum += val
      else
        non_ex_sum += val
      end
    end

    [ex_sum, non_ex_sum]
  end

  # Calcule les baselines (moyennes glissantes) et le statut de chaque jour.
  #
  # Champs calculés sur ExchangeTrueFlow :
  # - avg7/avg30/avg200 : moyenne de l'inflow sur les jours précédents (⚠️ on exclut le jour courant)
  # - ratio30           : inflow_du_jour / avg30
  # - status            : green / amber / red selon ratio30
  #
  # Choix important :
  # - On exclut le jour courant dans avg_over pour éviter "l'auto-inclusion"
  #   (sinon, le ratio est artificiellement lissé).
  #
  def compute_baselines_and_status!
    flows = ExchangeTrueFlow.order(:day).to_a

    flows.each_with_index do |f, idx|
      f.avg7   = avg_over(flows, idx, 7)
      f.avg30  = avg_over(flows, idx, 30)
      f.avg200 = avg_over(flows, idx, 200)

      f.ratio30 = ratio(f.inflow_btc, f.avg30)
      f.status  = status_from_ratio(f.ratio30)

      f.save! if f.changed?
    end
  end

  # Calcule une moyenne glissante de l'inflow sur les `window` jours précédents,
  # en excluant le jour courant.
  #
  # Exemple :
  # - idx = 10, window = 7
  # - on moyenne les lignes 3..9 (7 lignes)
  # - on exclut idx=10 pour éviter de biaiser le ratio
  #
  # @param flows [Array<ExchangeTrueFlow>]
  # @param idx [Integer]
  # @param window [Integer]
  # @return [BigDecimal, nil]
  def avg_over(flows, idx, window)
    to = idx - 1
    return nil if to < 0

    from = [0, to - (window - 1)].max
    slice = flows[from..to]
    return nil if slice.blank?

    sum = slice.sum { |x| x.inflow_btc.to_d }
    (sum / slice.size).to_d
  end

  # Calcule un ratio "valeur / baseline" avec sécurité.
  #
  # Retourne nil si baseline est vide ou <= 0.
  #
  # @param value [Numeric, BigDecimal, nil]
  # @param baseline [Numeric, BigDecimal, nil]
  # @return [BigDecimal, nil]
  def ratio(value, baseline)
    return nil if baseline.blank? || baseline.to_d <= 0
    (value.to_d / baseline.to_d).round(4)
  end

  # Transforme un ratio en statut (code couleur).
  #
  # Seuils :
  # - green  : ratio < 1.3  => normal
  # - amber  : ratio < 2.0  => tension
  # - red    : ratio >= 2.0 => excès (anomalie vs moyenne)
  #
  # @param ratio [Numeric, BigDecimal, nil]
  # @return [String, nil] "green" / "amber" / "red"
  def status_from_ratio(ratio)
    return nil if ratio.blank?
    r = ratio.to_d
    return "green" if r < 1.3
    return "amber" if r < 2.0
    "red"
  end
end
