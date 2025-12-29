# app/services/vault_watch_only_importer.rb
#
# ✅ Politique “Sparrow-first” (wallet complet)
# -------------------------------------------
# - Source de vérité: receive_descriptor + change_descriptor (Sparrow/Core)
# - Import watch-only: importdescriptors dans un wallet Core (vault_watchX)
# - Change branch importée avec internal:true
# - Support descriptors:
#   - non-ranged  -> deriveaddresses(desc)
#   - ranged (*)  -> deriveaddresses(desc, [i,i]) + importdescriptors avec range
# - Anti CookieOverflow: jamais de gros JSON dans les erreurs (logs only)
#
class VaultWatchOnlyImporter
  class Error < StandardError; end

  Result = Struct.new(
    :descriptor_kind,       # "receive" | "change"
    :desc_input,
    :desc_with_checksum,
    :is_ranged,
    :range_used,
    :index_used,
    :derived_address,
    :vault_address_before,
    :vault_address_after,
    :ismine,
    :solvable,
    :parent_desc,
    keyword_init: true
  )

  WalletImportResult = Struct.new(
    :receive,
    :change,
    keyword_init: true
  )

  DEFAULT_RANGE = [0, 1000].freeze

  def initialize(vault, logger: Rails.logger, wallet_rpc: BitcoinRpc.vault_watch)
    @vault      = vault
    @logger     = logger
    @wallet_rpc = wallet_rpc
  end

  # ==========================
  # Wallet complet (receive+change)
  # ==========================
  #
  # ✅ C’est LA méthode à appeler depuis le controller
  #
  # Par défaut:
  # - persist_address: false (car suivre “tout le wallet” => address n'est plus unique ni vérité)
  # - enforce_match: false (pareil)
  #
  def import_wallet!(
    timestamp: "now",
    active: false,
    range: nil,
    index: nil,
    persist_address: false,
    enforce_match: false
  )
    recv = @vault.receive_descriptor.to_s.strip
    chg  = @vault.change_descriptor.to_s.strip

    if recv.blank? && chg.blank?
      raise Error, "receive_descriptor/change_descriptor manquants"
    end

    # Import receive (internal: false)
    receive_res =
      if recv.present?
        import!(
          descriptor:       recv,
          timestamp:        timestamp,
          active:           active,
          range:            range,
          index:            index,
          persist_address:  persist_address,
          enforce_match:    enforce_match,
          internal:         false,
          descriptor_kind:  "receive"
        )
      end

    # Import change (internal: true)
    change_res =
      if chg.present?
        import!(
          descriptor:       chg,
          timestamp:        timestamp,
          active:           active,
          range:            range,
          index:            index,
          persist_address:  false,      # ✅ évite tout conflit de "address"
          enforce_match:    false,
          internal:         true,
          descriptor_kind:  "change"
        )
      end

    WalletImportResult.new(receive: receive_res, change: change_res)
  end

  # ==========================
  # Import d'un descriptor unique
  # ==========================
  def import!(
    descriptor:,
    timestamp: "now",
    active: false,
    range: nil,
    index: nil,
    persist_address: false,
    enforce_match: false,
    internal: nil,
    descriptor_kind: nil
  )
    desc_input = descriptor.to_s.strip
    raise Error, "descriptor manquant" if desc_input.blank?

    desc_with_checksum = normalize_descriptor!(desc_input)
    is_ranged          = ranged_descriptor?(desc_with_checksum)

    range_used = nil
    if is_ranged
      range_used = range || DEFAULT_RANGE
      raise Error, "range invalide (attendu [min,max])" unless valid_range?(range_used)
    end

    index_used = (index.nil? ? (@vault.derivation_index.presence || 0) : index).to_i
    index_used = 0 if index_used.negative?

    vault_address_before = @vault.address.presence

    # 1) Derive une adresse "référence"
    derived_addr = derive_one_address!(desc_with_checksum, is_ranged: is_ranged, index: index_used)

    # 2) address: uniquement si tu veux une "référence UI"
    # ⚠️ En wallet complet, mieux: NE PAS persister.
    if persist_address && derived_addr.present?
      if vault_address_before.present?
        if enforce_match && derived_addr != vault_address_before
          @logger.error("[VaultWatchOnlyImporter] address mismatch vault=#{@vault.id} kind=#{descriptor_kind} idx=#{index_used} derived=#{derived_addr} expected=#{vault_address_before}")
          raise Error, "descriptor ≠ vault.address (voir logs)"
        end
      else
        begin
          @vault.update!(address: derived_addr)
        rescue ActiveRecord::RecordNotUnique
          @logger.warn("[VaultWatchOnlyImporter] address uniqueness conflict vault=#{@vault.id} addr=#{derived_addr}")
          raise Error, "adresse déjà utilisée (index unique). Désactive persist_address."
        end
      end
    end

    vault_address_after = @vault.address.presence

    # 3) Import Core
    active_effective = (!!active) && is_ranged
    if active && !is_ranged
      @logger.warn("[VaultWatchOnlyImporter] active=true demandé mais non-ranged; forçage active=false vault=#{@vault.id} kind=#{descriptor_kind}")
    end

    payload = {
      "desc"      => desc_with_checksum,
      "timestamp" => timestamp,
      "active"    => active_effective
    }
    payload["range"]    = range_used if is_ranged
    payload["internal"] = internal unless internal.nil?

    res = @wallet_rpc.importdescriptors([payload])

    ok = res.is_a?(Array) && res.first.is_a?(Hash) && res.first["success"] == true
    unless ok
      @logger.error("[VaultWatchOnlyImporter] importdescriptors failed vault=#{@vault.id} kind=#{descriptor_kind} res=#{res.inspect}")
      raise Error, "importdescriptors a échoué (voir logs)"
    end

    # 4) getaddressinfo best-effort sur l’adresse “référence”
    ismine      = nil
    solvable    = nil
    parent_desc = nil

    addr_for_check = (persist_address ? vault_address_after : derived_addr).presence
    if addr_for_check.present?
      begin
        info        = @wallet_rpc.getaddressinfo(addr_for_check)
        ismine      = info["ismine"]
        solvable    = info["solvable"]
        parent_desc = info["parent_desc"]

        @logger.info("[VaultWatchOnlyImporter] vault=#{@vault.id} kind=#{descriptor_kind} addr=#{addr_for_check} ismine=#{ismine} solvable=#{solvable}")
        @logger.info("[VaultWatchOnlyImporter] parent_desc=#{parent_desc}")
      rescue => e
        @logger.warn("[VaultWatchOnlyImporter] getaddressinfo failed vault=#{@vault.id} kind=#{descriptor_kind} #{e.class}: #{e.message}")
      end
    end

    Result.new(
      descriptor_kind:      descriptor_kind,
      desc_input:           desc_input,
      desc_with_checksum:   desc_with_checksum,
      is_ranged:            is_ranged,
      range_used:           range_used,
      index_used:           index_used,
      derived_address:      derived_addr,
      vault_address_before: vault_address_before,
      vault_address_after:  vault_address_after,
      ismine:               ismine,
      solvable:             solvable,
      parent_desc:          parent_desc
    )
  end

  private

  def normalize_descriptor!(desc)
    out = @wallet_rpc.getdescriptorinfo(desc)
    out.fetch("descriptor")
  rescue => e
    @logger.error("[VaultWatchOnlyImporter] getdescriptorinfo failed vault=#{@vault.id} #{e.class}: #{e.message}")
    raise Error, "descriptor invalide (getdescriptorinfo a échoué)"
  end

  def ranged_descriptor?(desc_with_checksum)
    desc_with_checksum.include?("*")
  end

  def valid_range?(range)
    range.is_a?(Array) && range.size == 2 &&
      range[0].is_a?(Integer) && range[1].is_a?(Integer) &&
      range[0] >= 0 && range[1] >= range[0]
  end

  def derive_one_address!(desc_with_checksum, is_ranged:, index:)
    if is_ranged
      arr = @wallet_rpc.deriveaddresses(desc_with_checksum, [index, index])
      arr.is_a?(Array) ? arr.first : nil
    else
      arr = @wallet_rpc.deriveaddresses(desc_with_checksum)
      arr.is_a?(Array) ? arr.first : nil
    end
  rescue => e
    @logger.error("[VaultWatchOnlyImporter] deriveaddresses failed vault=#{@vault.id} #{e.class}: #{e.message}")
    raise Error, "impossible de dériver une adresse depuis le descriptor"
  end
end
