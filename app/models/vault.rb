# app/models/vault.rb
class Vault < ApplicationRecord
  # ====================
  #  CALLBACKS
  # ====================
  before_validation :set_default_network_and_status, on: :create

  # Legacy: xpub -> pubkeys uniquement si on est en mode legacy
  before_validation :auto_derive_keys_from_xpubs, on: :create, if: -> { legacy_builder_mode? }

  has_many :vault_addresses, dependent: :destroy

  # ====================
  #  CONSTS & STATUTS
  # ====================
  NETWORKS = %w[mainnet testnet regtest signet].freeze
  STATUSES = %w[draft active closed].freeze

  SCAN_STATUS_OK      = "ok".freeze
  SCAN_STATUS_RUNNING = "running".freeze
  SCAN_STATUS_ERROR   = "error".freeze

  PSBT_MODES = %w[normal recovery].freeze

  # ====================
  #  MODE SWITCH
  # ====================
  # Nouvelle politique: "wallet complet" si on a receive+change descriptors
  def watch_only_wallet_mode?
    receive_descriptor.present? && change_descriptor.present?
  end

  # Legacy si pas de descriptors (ou incomplets)
  def legacy_builder_mode?
    !watch_only_wallet_mode?
  end

  # ====================
  #  VALIDATIONS
  # ====================
  validates :label, presence: true
  validates :network, inclusion: { in: NETWORKS }, allow_blank: true
  validates :status,  inclusion: { in: STATUSES }, allow_blank: true

  # ✅ Politique "suivre tout le wallet"
  # - On exige les 2 descriptors dès qu'on n'est plus en brouillon
  validates :receive_descriptor, presence: true, if: -> { status != "draft" }
  validates :change_descriptor,  presence: true, if: -> { status != "draft" }

  # Range de scan (gap limit / range)
  validates :scan_range,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 5000 }

  # --- Legacy (optionnel) ---
  # Si tu veux encore supporter l'ancien mode sans descriptors :
  validates :xpub_a, :xpub_b, presence: true, if: -> { legacy_builder_mode? && status != "draft" }

  validates :pubkey_a, :pubkey_b, presence: true, if: -> { legacy_builder_mode? }

  # pubkeys compressées : 33 octets => 66 hex chars, commencent par 02/03
  validates :pubkey_a,
            format: { with: /\A0[23][0-9a-fA-F]{64}\z/, message: "doit être une clé publique compressée (hex 66 chars)" },
            allow_blank: true

  validates :pubkey_b,
            format: { with: /\A0[23][0-9a-fA-F]{64}\z/, message: "doit être une clé publique compressée (hex 66 chars)" },
            allow_blank: true

  validates :delay_blocks,
            presence: true,
            numericality: { only_integer: true, greater_than: 0 },
            if: -> { legacy_builder_mode? }

  validates :xpub_a, length: { maximum: 255 }, allow_blank: true
  validates :xpub_b, length: { maximum: 255 }, allow_blank: true

  # ==============================
  #   HELPERS → 100% MODE CACHE
  # ==============================
  def has_address?
    address.present?
  end

  def balance_sats
    self[:balance_sats] || 0
  end

  def balance_btc
    balance_sats.to_d / 100_000_000
  end

  def scanned?
    last_scanned_at.present?
  end

  def last_scan_ok?
    last_scan_status == SCAN_STATUS_OK
  end

  def utxos_count
    self[:utxos_count] || 0
  end

  def utxos_unconfirmed_count
    self[:utxos_unconfirmed_count] || 0
  end

  def csv_delay_blocks
    delay_blocks.to_i
  end

  # ====================
  #  SCAN STATE METHODS
  # ====================
  def scan_running?
    last_scan_status == SCAN_STATUS_RUNNING
  end

  def mark_scan_running!
    update!(
      last_scan_status: SCAN_STATUS_RUNNING,
      last_scan_error:  nil,
      last_scanned_at:  Time.current
    )
  end

  def mark_scan_ok!(balance_sats:, utxos_count:, utxos_unconfirmed_count:)
    update!(
      balance_sats:            balance_sats,
      utxos_count:             utxos_count,
      utxos_unconfirmed_count: utxos_unconfirmed_count,
      last_scan_status:        SCAN_STATUS_OK,
      last_scanned_at:         Time.current
    )
  end

  def mark_scan_error!(message)
    update(
      last_scan_status: SCAN_STATUS_ERROR,
      last_scan_error:  message,
      last_scanned_at:  Time.current
    )
  end

  # ==========================
  #   PRIVATE
  # ==========================
  private

  def set_default_network_and_status
    self.network ||= "mainnet"
    self.status  ||= "draft"
  end

  # Legacy uniquement
  def auto_derive_keys_from_xpubs
    return if xpub_a.blank? || xpub_b.blank?
    return if pubkey_a.present? && pubkey_b.present?

    result = DerivePubkeyRunner.call(xpub_a, xpub_b)

    self.pubkey_a  ||= result[:pubkey_a]
    self.address_a ||= result[:address_a]
    self.pubkey_b  ||= result[:pubkey_b]
    self.address_b ||= result[:address_b]
  rescue => e
    Rails.logger.error("[Vault] Erreur derive_pubkey: #{e.class} - #{e.message}")
    errors.add(:base, "Erreur lors de la dérivation des clés depuis les xpub : #{e.message}")
  end
end
