# frozen_string_literal: true

# app/controllers/blocks_controller.rb
#
# 🧱 Contrôleur "Blocks" : exploration de la blockchain + surcouche BRC-20
#
# OBJECTIF
# --------
# Ce contrôleur permet :
# 1) d'afficher une liste paginée des blocs récents (index)
# 2) de rechercher un bloc :
#    - par hauteur (height)
#    - par date (jour)
# 3) d'afficher le détail d'un bloc (show) :
#    - transactions du bloc (via RPC)
#    - événements BRC-20 détectés dans ce bloc (via Brc20Event)
#    - filtre optionnel : afficher uniquement les transactions contenant un "deploy"
#
# SOURCES DE DONNÉES
# ------------------
# - Bitcoin RPC (node local) : informations de blocs et transactions
# - Base SQL :
#   - Brc20Event : events BRC-20 par txid et block_height
#   - Brc20BlockStat : stats agrégées par bloc (nombre d'opérations, ticks, etc.)
#
# CHOIX D'ARCHITECTURE
# --------------------
# - Le RPC sert à obtenir les données "brutes blockchain" (blocs/tx).
# - La DB sert à obtenir les données "analysées BRC-20" (indexées et rapides).
# - L'index évite de calculer du BRC-20 à la volée : on lit Brc20BlockStat.
#
# PERFORMANCE / LIMITES
# ---------------------
# - L'index fait un get_block_hash + get_block pour chaque bloc affiché :
#   en local c'est OK, mais à grande échelle ça peut être coûteux.
# - La recherche par date fait une recherche binaire, puis avance jusqu'au dernier bloc du jour :
#   la deuxième phase est linéaire sur le nombre de blocs de la journée.
# - Le show charge le bloc avec verbosity 2 (tx complètes) : c'est plus lourd.
#
require "set"

class BlocksController < ApplicationController
  # Initialise le client RPC avant chaque action.
  before_action :init_rpc

  # GET /blocks
  #
  # Affiche la liste des blocs (et quelques métriques) avec 3 modes :
  # 1) Recherche par height (params[:height])
  # 2) Recherche par date (params[:day])
  # 3) Mode normal paginé : blocs récents
  #
  # Variables exposées à la vue :
  # - @blocks        : liste de Hash "row" construits par build_block_row
  # - @has_next_page : pagination
  # - @error         : message d'erreur si besoin
  #
  def index
    # Hauteur du dernier bloc connu par le node (tip)
    tip_height = @rpc.get_block_count.to_i

    # Pagination simple
    @per_page = 50
    @page     = params[:page].to_i
    @page     = 1 if @page < 1

    # Paramètres de recherche
    @search_height = params[:height].presence
    @search_day    = params[:day].presence

    # ------------------------------------------------------------------
    # 1️⃣ Recherche par numéro de bloc (height)
    # ------------------------------------------------------------------
    if @search_height
      height = @search_height.to_i

      # Validation de plage
      if height < 0 || height > tip_height
        @error         = "Bloc #{height} en dehors de la plage 0..#{tip_height}"
        @blocks        = []
        @has_next_page = false
        return
      end

      heights = [height]

      # Charge les stats BRC-20 (si elles existent) pour ce bloc
      stats_by_height, scanned_heights = load_brc20_block_stats(heights)

      # Construit une ligne d'affichage pour chaque height
      @blocks = heights.map do |h|
        build_block_row(h, stats_by_height, scanned_heights)
      end

      @has_next_page = false
      return
    end

    # ------------------------------------------------------------------
    # 2️⃣ Recherche par date (JJ/MM/AAAA ou AAAA-MM-JJ)
    # ------------------------------------------------------------------
    if @search_day
      begin
        day = Date.parse(@search_day)
      rescue ArgumentError
        @error         = "Date invalide"
        @blocks        = []
        @has_next_page = false
        return
      end

      # Trouve la plage de blocks correspondant à cette journée (timezone Paris)
      from_h, to_h = find_block_range_for_day(day, tip_height)

      if from_h.nil? || to_h.nil?
        @error         = "Aucun bloc trouvé pour le #{day.strftime('%d/%m/%Y')}."
        @blocks        = []
        @has_next_page = false
        return
      end

      # On liste les heights de la journée en ordre décroissant (plus récents en haut)
      heights = (from_h..to_h).to_a.reverse

      stats_by_height, scanned_heights = load_brc20_block_stats(heights)

      @blocks = heights.map do |h|
        build_block_row(h, stats_by_height, scanned_heights)
      end

      @has_next_page = false
      return
    end

    # ------------------------------------------------------------------
    # 3️⃣ Mode normal : pagination sur les blocs les plus récents
    # ------------------------------------------------------------------
    start_height = tip_height - (@page - 1) * @per_page
    end_height   = [start_height - @per_page + 1, 0].max

    # Liste des heights (plus récents en haut)
    heights = (end_height..start_height).to_a.reverse

    stats_by_height, scanned_heights = load_brc20_block_stats(heights)

    @blocks = heights.map do |h|
      build_block_row(h, stats_by_height, scanned_heights)
    end

    # Il y a une page suivante tant qu'on n'a pas atteint 0
    @has_next_page = end_height > 0
  rescue => e
    # En cas d'erreur inattendue (RPC down, bug, etc.), on sécurise la page.
    @error         = e.message
    @blocks        = []
    @has_next_page = false
  end

  # GET /blocks/:id
  #
  # Affiche le détail d'un bloc :
  # - infos de base (hash, height)
  # - bloc complet via RPC avec verbosity 2 (transactions complètes)
  # - événements BRC-20 par transaction (via Brc20Event)
  # - option de filtre sur les opérations "deploy"
  #
  # Paramètres de filtre :
  # - params[:deploy_tick]
  #   - si présent : filtre sur un tick précis (case-insensitive)
  #   - si vide mais formulaire soumis : filtre sur "au moins un deploy"
  #
  # Variables exposées à la vue :
  # - @block_hash, @block_height
  # - @block
  # - @tx_rows : tableau de Hash décrivant chaque transaction du bloc
  #
  def show
    height = params[:id].to_i

    # 1) Hash du bloc
    block_hash    = @rpc.get_block_hash(height)
    @block_hash   = block_hash
    @block_height = height

    # 2) Bloc complet (verbosity 2 : inclut les tx complètes)
    @block = @rpc.get_block(block_hash, 2)
    txs    = @block["tx"] || []

    # 3) Tous les événements BRC-20 détectés dans ce bloc (stockés en base)
    events         = Brc20Event.where(block_height: height)
    events_by_txid = events.group_by(&:txid)

    # ------------------------------------------------------------------
    # 🔍 Paramètres du filtre "deploy"
    # ------------------------------------------------------------------
    deploy_tick_raw   = params[:deploy_tick]            # saisie utilisateur
    deploy_tick_param = deploy_tick_raw.to_s.strip.downcase
    filter_by_deploy  = params.key?(:deploy_tick)       # true seulement si formulaire soumis

    # Logs utiles en debug (surtout quand on cherche pourquoi un filtre renvoie vide)
    Rails.logger.info "[BRC20 SHOW] params=#{params.to_unsafe_h.inspect}"
    Rails.logger.info "[BRC20 SHOW] filter_by_deploy=#{filter_by_deploy}, deploy_tick_param=#{deploy_tick_param.inspect}"

    # ------------------------------------------------------------------
    # Construction des lignes par transaction
    # ------------------------------------------------------------------
    @tx_rows = txs.each_with_index.map do |tx, idx|
      txid = tx["txid"]
      evts = events_by_txid[txid] || []

      # Tous les ticks vus dans les events de la tx
      ticks = evts.map(&:tick).compact.uniq

      # On ne garde que les events "deploy"
      deploy_evts  = evts.select { |e| e.op.to_s.downcase == "deploy" }
      deploy_ticks = deploy_evts.map(&:tick).compact.uniq

      {
        index:              idx,
        tx:                 tx,
        txid:               txid,
        has_brc20:          evts.any?,
        brc20_count:        evts.size,
        brc20_ticks:        ticks,
        brc20_deploy_count: deploy_evts.size,
        brc20_deploy_ticks: deploy_ticks
      }
    end

    # ------------------------------------------------------------------
    # 4) Application du filtre "deploy"
    # ------------------------------------------------------------------
    if filter_by_deploy
      if deploy_tick_param.present?
        # Cas 1 : tick saisi -> garder seulement les tx qui ont un deploy pour CE tick
        @tx_rows.select! do |row|
          row[:brc20_deploy_ticks].any? { |t| t.to_s.downcase == deploy_tick_param }
        end
      else
        # Cas 2 : formulaire soumis mais tick vide -> garder toutes les tx qui ont AU MOINS un deploy
        @tx_rows.select! do |row|
          row[:brc20_deploy_count].to_i > 0
        end
      end
    end
  rescue => e
    # Si le RPC plante ou si le bloc n'est pas accessible, on protège la page.
    @error   = "Bitcoin RPC error: #{e.message}"
    @block   = nil
    @tx_rows = []
  end

  private

  # Initialise le client Bitcoin RPC (node local).
  #
  # Pourquoi un before_action ?
  # - Pour éviter de répéter BitcoinRpc.new dans chaque action
  # - Pour garantir que @rpc est toujours disponible
  #
  def init_rpc
    @rpc = BitcoinRpc.new
  end

  # ========= Helpers BRC-20 pour l'index =========

  # Charge les stats BRC-20 (opérations et ticks) pour un ensemble de hauteurs de blocs.
  #
  # Source : table Brc20BlockStat (pré-calculée par ton scanner).
  #
  # Résultat :
  # - stats_by_height : Hash indexé par height
  #   stats_by_height[height] = { ops: Integer, ticks: [String, ...] }
  # - scanned_heights : Set des heights présents en base (permet d'afficher "scanné / non scanné")
  #
  # Pourquoi ce helper ?
  # - Évite de faire N requêtes par bloc côté vue
  # - Permet d'afficher rapidement "combien d'ops BRC-20 dans ce bloc"
  #
  # @param heights [Array<Integer>]
  # @return [Array<Hash, Set<Integer>>]
  def load_brc20_block_stats(heights)
    return [{}, Set.new] if heights.blank?

    stats = Brc20BlockStat.where(block_height: heights)

    stats_by_height = {}

    stats.each do |row|
      h = row.block_height

      stats_by_height[h] ||= { ops: 0, ticks: Set.new }

      # Total des opérations BRC-20 du bloc
      stats_by_height[h][:ops] +=
        row.deploy_count.to_i +
        row.mint_count.to_i +
        row.transfer_count.to_i

      # Stockage des ticks rencontrés (si la colonne tick existe et est remplie)
      stats_by_height[h][:ticks] << row.tick if row.respond_to?(:tick) && row.tick.present?
    end

    # Conversion des Set -> Array (plus simple à afficher en vue)
    stats_by_height.each_value do |v|
      v[:ticks] = v[:ticks].to_a
    end

    scanned_heights = stats.map(&:block_height).uniq.to_set

    [stats_by_height, scanned_heights]
  end

  # Construit une "ligne" (row) affichable dans l'index.
  #
  # Données RPC :
  # - hash du bloc
  # - block header (verbosity 1)
  #
  # Données BRC-20 :
  # - nombre d'opérations (ops)
  # - ticks impliqués
  # - flag "scanné"
  #
  # @param height [Integer]
  # @param stats_by_height [Hash]
  # @param scanned_heights [Set<Integer>]
  # @return [Hash]
  def build_block_row(height, stats_by_height, scanned_heights)
    hash  = @rpc.get_block_hash(height)
    block = @rpc.get_block(hash, 1)

    stat = stats_by_height[height] || {}

    {
      height:          height,
      hash:            hash,
      time:            Time.at(block["time"]).in_time_zone("Europe/Paris"),
      tx_count:        (block["tx"] || []).size,
      size_bytes:      block["size"],
      weight:          block["weight"],
      brc20_ops_count: stat[:ops]   || 0,
      brc20_ticks:     stat[:ticks] || [],
      brc20_scanned:   scanned_heights.include?(height)
    }
  end

  # ========= Recherche par date =========

  # Trouve la plage de blocs correspondant à une journée donnée (heure de Paris).
  #
  # Retour :
  # - [first_height, last_height]
  #
  # Méthode :
  # 1) Recherche binaire du premier bloc dont le timestamp >= début de journée
  # 2) Puis avance séquentiellement jusqu'au dernier bloc <= fin de journée
  #
  # Pourquoi ?
  # - Le timestamp des blocs n'est pas une progression parfaitement régulière
  # - La recherche binaire évite de parcourir tout l'historique
  #
  # Limites :
  # - La phase 2 est linéaire sur le nombre de blocs du jour (acceptable)
  #
  # @param day [Date]
  # @param tip_height [Integer]
  # @return [Array<(Integer, Integer)>, Array<(nil, nil)>]
  def find_block_range_for_day(day, tip_height)
    target_start = day.beginning_of_day.in_time_zone("Europe/Paris").to_i
    target_end   = day.end_of_day.in_time_zone("Europe/Paris").to_i

    # 1) Binary search : premier bloc >= début de journée
    low   = 0
    high  = tip_height
    first = nil

    while low <= high
      mid = (low + high) / 2
      t   = block_time_for_height(mid)

      if t < target_start
        low = mid + 1
      else
        first = mid
        high  = mid - 1
      end
    end

    return [nil, nil] if first.nil?

    # 2) Avance jusqu'au dernier bloc <= fin de journée
    last = first
    while last + 1 <= tip_height
      t = block_time_for_height(last + 1)
      break if t > target_end
      last += 1
    end

    [first, last]
  end

  # Renvoie le timestamp Unix (en secondes) d'un bloc à partir de sa hauteur.
  #
  # Utilisé principalement par la recherche par date.
  #
  # @param height [Integer]
  # @return [Integer] timestamp Unix
  def block_time_for_height(height)
    hash  = @rpc.get_block_hash(height)
    block = @rpc.get_block(hash, 1)
    block["time"].to_i
  end

  # ==== 🔧 Helper d’extraction du tick ====
  #
  # Extrait un "tick" BRC-20 depuis une inscription / structure JSON potentiellement variable.
  #
  # Pourquoi autant de cas ?
  # - Selon la source, un objet "inscription" peut être :
  #   - un modèle ActiveRecord/PORO avec méthode tick
  #   - un Hash Ruby symbolisé
  #   - un Hash JSON (clés string)
  # - Le tick peut être au niveau racine, dans :op, ou dans :data
  #
  # @param ins [Object] inscription / structure à analyser
  # @return [String, nil] tick trouvé, sinon nil
  def extract_tick_from_inscription(ins)
    # Cas 1 : ActiveRecord / PORO avec méthode `tick`
    return ins.tick if ins.respond_to?(:tick)

    return nil unless ins.is_a?(Hash)

    # Cas 2 : directement au premier niveau
    return ins[:tick]  if ins.key?(:tick)  && ins[:tick].present?
    return ins["tick"] if ins.key?("tick") && ins["tick"].present?

    # Cas 3 : dans une clé :op
    if ins.key?(:op)
      op = ins[:op]
      if op.is_a?(Hash)
        return op[:tick]  if op.key?(:tick)  && op[:tick].present?
        return op["tick"] if op.key?("tick") && op["tick"].present?
      end
    end

    if ins.key?("op")
      op = ins["op"]
      if op.is_a?(Hash)
        return op[:tick]  if op.key?(:tick)  && op[:tick].present?
        return op["tick"] if op.key?("tick") && op["tick"].present?
      end
    end

    # Cas 4 : parfois rangé dans :data, :parsed, etc.
    if ins.key?(:data)
      data = ins[:data]
      if data.is_a?(Hash)
        return data[:tick]  if data.key?(:tick)  && data[:tick].present?
        return data["tick"] if data.key?("tick") && data["tick"].present?
      end
    end

    if ins.key?("data")
      data = ins["data"]
      if data.is_a?(Hash)
        return data[:tick]  if data.key?(:tick)  && data[:tick].present?
        return data["tick"] if data.key?("tick") && data["tick"].present?
      end
    end

    nil
  end
end
