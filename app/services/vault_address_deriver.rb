# app/services/vault_address_deriver.rb
#
# Dérive et persiste les adresses du wallet (receive + change)
# à partir des descriptors Bitcoin Core (ranged /0/* et /1/*).
#
# - upsert sur (vault_id, kind, index)
# - garantit unicité d'address (index unique sur vault_addresses.address)
#
class VaultAddressDeriver
  class Error < StandardError; end

  KINDS = {
    "receive" => :receive_descriptor,
    "change"  => :change_descriptor
  }.freeze

  def initialize(vault, wallet_rpc: BitcoinRpc.vault_watch, logger: Rails.logger)
    @vault      = vault
    @wallet_rpc = wallet_rpc
    @logger     = logger
  end

  # Dérive de start..stop (inclus) pour receive+change, et persiste.
  # Retourne un hash: { receive: n, change: n }
  def derive_and_persist!(start_index: 0, stop_index: nil)
    stop_index = (stop_index.nil? ? @vault.scan_range.to_i : stop_index.to_i)
    raise Error, "scan_range invalide" if stop_index < start_index || start_index.negative?

    counts = {}

    KINDS.each do |kind, attr|
      desc = @vault.public_send(attr).to_s.strip
      raise Error, "#{attr} manquant" if desc.blank?

      desc = normalize_descriptor!(desc) # canonical + checksum
      addrs = @wallet_rpc.deriveaddresses(desc, [start_index, stop_index])
      raise Error, "deriveaddresses vide pour #{kind}" unless addrs.is_a?(Array) && addrs.any?

      upsert_rows = addrs.each_with_index.map do |address, i|
        idx = start_index + i
        {
          vault_id:    @vault.id,
          kind:        kind,
          index:       idx,
          address:     address,
          created_at:  Time.current,
          updated_at:  Time.current
        }
      end

      # Rails 7: upsert_all nécessite un unique index pour matcher
      # On a add_index :vault_addresses, [:vault_id,:kind,:index], unique: true
      VaultAddress.upsert_all(
        upsert_rows,
        unique_by: :index_vault_addresses_on_vault_id_and_kind_and_index
      )

      counts[kind.to_sym] = upsert_rows.size
      @logger.info("[VaultAddressDeriver] vault=#{@vault.id} kind=#{kind} derived=#{upsert_rows.size} range=#{start_index}..#{stop_index}")
    end

    counts
  rescue ActiveRecord::RecordNotUnique => e
    # Conflit sur vault_addresses.address (unique)
    @logger.warn("[VaultAddressDeriver] address unique conflict vault=#{@vault.id}: #{e.class} #{e.message}")
    raise Error, "une adresse dérivée est déjà utilisée par un autre wallet (unique index address)"
  end

  private

  def normalize_descriptor!(desc)
    @wallet_rpc.getdescriptorinfo(desc).fetch("descriptor")
  rescue => e
    @logger.error("[VaultAddressDeriver] getdescriptorinfo failed vault=#{@vault.id} #{e.class}: #{e.message}")
    raise Error, "descriptor invalide"
  end
end
