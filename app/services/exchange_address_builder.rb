# frozen_string_literal: true

# app/services/exchange_address_builder.rb
#
# 🏗️ Construction / enrichissement du "set d'adresses exchange"
#
# OBJECTIF
# --------
# Ce service construit (et enrichit au fil du temps) la table ExchangeAddress,
# qui sert ensuite de base au True Exchange Flow.
#
# L'idée :
# - on part des WhaleAlerts "probablement liées à un exchange"
# - puis on "apprend" des adresses vues dans leurs transactions
# - on incrémente un compteur d'occurrences pour mesurer la fiabilité
#
# Pourquoi faire ça ?
# - On n'a pas une liste parfaite d'adresses d'exchanges
# - Les exchanges changent / tournent / batchent / utilisent des hot wallets
# - Donc on bâtit un set "auto-détecté" à partir de signaux on-chain
#
# PRINCIPE D'APPRENTISSAGE
# ------------------------
# Pour chaque WhaleAlert qualifiée :
# 1) On apprend depuis les INPUTS :
#    - adresse(s) qui dépensent des UTXO
#    - souvent des hot wallets / hubs / wallets opérationnels
#
# 2) On apprend depuis les OUTPUTS :
#    - adresse(s) qui reçoivent des BTC
#    - peut être des adresses de dépôt, des wallets internes, etc.
#
# On ajoute/enrichit ensuite ExchangeAddress :
# - occurrences : combien de fois l'adresse a été vue (signal principal)
# - confidence  : score simplifié (ici, juste +1 plafonné à 100)
# - first_seen_at / last_seen_at : bornes temporelles
# - source : d'où vient l'observation (inputs / outputs), pour debug
#
# LIMITES / RISQUES
# -----------------
# - Les adresses trouvées peuvent inclure :
#   - des contreparties
#   - des wallets de baleines
#   - des services tiers / mixers / custodians
# - D'où l'importance du seuil "min occurrences" (ex: 8) dans le True Flow :
#   on ne considère "exchange" que les adresses vues fréquemment.
#
# PERFORMANCE
# -----------
# - Les transactions sont récupérées via BitcoinRpc (Bitcoin Core)
# - Un cache en mémoire (@tx_cache) évite de refetch plusieurs fois la même txid
#
class ExchangeAddressBuilder
  # Seuil minimal de WhaleAlert.exchange_likelihood pour inclure une alerte dans l'apprentissage
  EX_MIN = 70

  # Point d'entrée principal (convention Rails)
  #
  # @param days_back [Integer] nombre de jours en arrière à analyser (ex: 14)
  #
  # Exemple :
  #   ExchangeAddressBuilder.call(days_back: 30)
  #
  def self.call(days_back: 14)
    new(days_back: days_back).call
  end

  # Initialise le service.
  #
  # @param days_back [Integer] période d'apprentissage (en jours)
  #
  # Effets :
  # - instancie un client BitcoinRpc
  # - instancie un cache mémoire de transactions
  #
  def initialize(days_back:)
    @days_back = days_back
    @rpc = BitcoinRpc.new
    @tx_cache = {}
  end

  # Exécute l'apprentissage sur la période demandée.
  #
  # Étapes :
  # 1) Détermine la date "since" (maintenant - days_back)
  # 2) Sélectionne les WhaleAlerts :
  #    - exchange_likelihood >= EX_MIN
  #    - récentes (block_time si disponible, sinon created_at)
  # 3) Pour chaque alerte :
  #    - récupère la transaction
  #    - définit seen_at (block_time ou created_at)
  #    - apprend depuis les inputs
  #    - apprend depuis les outputs
  #
  # Remarque :
  # - Ce service "enrichit" le set progressivement.
  # - Il ne supprime pas d'adresses : on laisse au seuil d'occurrences le rôle de filtrer.
  #
  # @return [void]
  def call
    since = @days_back.days.ago

    alerts = WhaleAlert
      .where("exchange_likelihood >= ?", EX_MIN)
      .where(
        "(block_time IS NOT NULL AND block_time >= ?) OR (block_time IS NULL AND created_at >= ?)",
        since, since
      )

    alerts.find_each do |a|
      tx = fetch_tx(a.txid, a.block_height)
      next if tx.blank?

      seen_at = a.block_time || a.created_at

      # 1) Apprentissage depuis les INPUTS :
      #    adresses qui dépensent (souvent hot wallets / hubs)
      learn_from_inputs(tx, seen_at: seen_at)

      # 2) Apprentissage depuis les OUTPUTS :
      #    adresses qui reçoivent (dépôts / interne)
      learn_from_outputs(tx, seen_at: seen_at)
    rescue BitcoinRpc::Error
      # Si une tx est indisponible / RPC down : on saute et on continue
      next
    end
  end

  private

  # Apprend des adresses côté INPUTS (vin).
  #
  # Logique :
  # - Pour chaque input non-coinbase :
  #   - on récupère la transaction précédente (prev_txid)
  #   - on récupère l'adresse de la sortie dépensée (prev_vout)
  #   - on enregistre cette adresse comme candidate "exchange"
  #
  # Pourquoi les inputs ?
  # - Les exchanges utilisent souvent des hot wallets qui dépensent fréquemment
  # - Donc l'adresse "source" peut révéler des hubs opérationnels
  #
  # Limites :
  # - Peut aussi attraper des wallets de baleines / services très actifs
  # - D'où : occurrences + seuil en aval
  #
  # @param tx [Hash] transaction décodée
  # @param seen_at [Time] date/heure d'observation (block_time ou created_at)
  # @return [void]
  def learn_from_inputs(tx, seen_at:)
    return if tx["vin"].blank?

    tx["vin"].each do |vin|
      next if vin["coinbase"].present?

      prev_txid = vin["txid"]
      prev_vout = vin["vout"]
      next if prev_txid.blank? || prev_vout.nil?

      prev = fetch_tx(prev_txid) # txindex synced => OK (hypothèse)
      addr = prevout_address(prev, prev_vout)
      next if addr.blank?

      upsert_exchange_address!(addr, seen_at: seen_at, source: "whale_alert_inputs")
    end
  end

  # Apprend des adresses côté OUTPUTS (vout).
  #
  # Logique :
  # - Pour chaque output monétaire :
  #   - ignore OP_RETURN (nulldata)
  #   - ignore value <= 0
  #   - extrait l'adresse de destination
  #   - enregistre cette adresse comme candidate "exchange"
  #
  # Pourquoi les outputs ?
  # - Les exchanges reçoivent des dépôts sur des adresses de réception
  # - Les mouvements internes/batching peuvent aussi révéler des adresses utilisées par l'exchange
  #
  # Limites :
  # - Peut capturer des adresses de contreparties (ex: la baleine qui reçoit)
  # - D'où : occurrences + seuil en aval
  #
  # @param tx [Hash] transaction décodée
  # @param seen_at [Time] date/heure d'observation
  # @return [void]
  def learn_from_outputs(tx, seen_at:)
    vouts = Array(tx["vout"])
    return if vouts.empty?

    vouts.each do |vout|
      value = begin
        BigDecimal(vout["value"].to_s)
      rescue
        0.to_d
      end
      next if value <= 0

      spk = vout["scriptPubKey"] || {}
      next if spk["type"].to_s == "nulldata" # OP_RETURN

      addr = scriptpubkey_address(spk)
      next if addr.blank?

      upsert_exchange_address!(addr, seen_at: seen_at, source: "whale_alert_outputs")
    end
  end

  # Récupère une transaction décodée via Bitcoin Core RPC, avec cache mémoire.
  #
  # Stratégie :
  # - retourne le cache si txid déjà vue
  # - si block_height est présent :
  #   - calcule blockhash et appelle getrawtransaction(txid, true, blockhash)
  # - sinon (ou si erreur) :
  #   - fallback getrawtransaction(txid, true, nil)
  #
  # Pourquoi ce fallback ?
  # - Certains nodes acceptent mieux un appel "sans blockhash" si le premier échoue
  #
  # @param txid [String]
  # @param block_height [Integer, nil]
  # @return [Hash, nil]
  def fetch_tx(txid, block_height = nil)
    return @tx_cache[txid] if @tx_cache.key?(txid)

    blockhash = (block_height.present? ? @rpc.getblockhash(block_height) : nil)
    tx = @rpc.getrawtransaction(txid, true, blockhash)
    @tx_cache[txid] = tx
  rescue BitcoinRpc::Error
    tx = @rpc.getrawtransaction(txid, true, nil)
    @tx_cache[txid] = tx
  end

  # Extrait l'adresse associée à une sortie (vout) d'une transaction précédente.
  #
  # Étapes :
  # - retrouver la vout par son index ("n" == vout_index)
  # - récupérer scriptPubKey
  # - convertir scriptPubKey en adresse via scriptpubkey_address
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

  # Convertit un scriptPubKey en adresse "lisible", si possible.
  #
  # Tentatives (ordre) :
  # 1) spk["address"]
  # 2) spk["addresses"].first
  # 3) sinon : utiliser le descriptor spk["desc"] + deriveaddresses(desc)
  #
  # Pourquoi deriveaddresses ?
  # - Bitcoin Core peut fournir un descriptor plutôt qu'une adresse directe.
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

  # Insère ou met à jour une adresse dans ExchangeAddress.
  #
  # Règles :
  # - occurrences : incrémenté à chaque observation (signal principal)
  # - confidence  : incrémenté (+1) plafonné à 100 (score secondaire)
  # - first_seen_at : fixé si vide
  # - last_seen_at  : mis à jour à chaque observation
  # - source : concaténation des sources (inputs/outputs) pour debug
  #
  # Pourquoi stocker "source" ?
  # - Aide au debug : on sait si l'adresse a été apprise via inputs, outputs, ou les deux.
  #
  # @param addr [String] adresse Bitcoin observée
  # @param seen_at [Time] date d'observation
  # @param source [String] étiquette de provenance (debug-friendly)
  # @return [void]
  def upsert_exchange_address!(addr, seen_at:, source:)
    row = ExchangeAddress.find_or_initialize_by(address: addr)

    # Si on a déjà une source, on concatène (debug-friendly)
    if row.source.present? && !row.source.to_s.split(",").include?(source)
      row.source = "#{row.source},#{source}"
    else
      row.source ||= source
    end

    row.occurrences = row.occurrences.to_i + 1
    row.confidence  = [100, row.confidence.to_i + 1].min

    row.first_seen_at ||= seen_at
    row.last_seen_at = seen_at

    row.save!
  end
end
