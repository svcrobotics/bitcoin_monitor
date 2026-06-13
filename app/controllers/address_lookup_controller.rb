# frozen_string_literal: true

class AddressLookupController < ApplicationController
  def search
    raw = params[:q].to_s.strip

    if raw.blank?
      redirect_back fallback_location: root_path, alert: "Veuillez saisir une adresse Bitcoin."
      return
    end

    redirect_to address_lookup_path(address: raw)
  end

  def show
    @query_address = params[:address].to_s.strip

    validation = BitcoinRpc.new(wallet: nil).validateaddress(@query_address)
    @address_valid = validation["isvalid"] == true
    @validation_error = validation["error"]

    unless @address_valid
      flash.now[:alert] = "Adresse invalide." if @validation_error.blank?
      return
    end

    @address_record = Address.find_by(address: @query_address)

    unless @address_record
      @observed = false
      @cluster = nil
      @user_message = nil
      @cluster_label = nil
      @cluster_tone = :neutral
      @linked_addresses = []
      @links = []
      @cluster_total_sent_sats = 0
      return
    end

    @observed = true
    @cluster = @address_record.cluster

    @cluster_total_sent_sats =
      if @cluster.present?
        @cluster.addresses.sum(:total_sent_sats)
      else
        @address_record.total_sent_sats.to_i
      end

    @user_message = build_user_message(cluster: @cluster)

    if @cluster.present?
      @cluster_label, @cluster_tone = cluster_summary_meta(@cluster.address_count)

      @linked_addresses = @cluster.addresses
        .where.not(id: @address_record.id)
        .order(total_sent_sats: :desc, id: :asc)
        .limit(10)

      cluster_address_ids = @cluster.addresses.limit(500).pluck(:id)

      @links = AddressLink
        .where(address_a_id: cluster_address_ids)
        .or(AddressLink.where(address_b_id: cluster_address_ids))
        .select(:txid, :block_height)
        .order(block_height: :desc, id: :desc)
        .to_a
        .uniq { |link| link.txid }
        .first(10)
    else
      @cluster_label = "Adresse observée"
      @cluster_tone = :neutral
      @linked_addresses = []
      @links = []
    end
  end

  private

  def cluster_summary_meta(address_count)
    case address_count.to_i
    when 0, 1
      ["Adresse isolée", :neutral]
    when 2..20
      ["Petit cluster", :low]
    when 21..1000
      ["Cluster moyen", :medium]
    else
      ["Cluster large", :large]
    end
  end

  def build_user_message(cluster:)
    return nil unless cluster.present?

    address_count = cluster.address_count.to_i

    title, tone =
      case address_count
      when 0, 1
        ["Adresse isolée", :neutral]
      when 2..20
        ["Petit cluster observé", :neutral]
      when 21..1000
        ["Cluster multi-input observé", :info]
      else
        ["Grand cluster multi-input observé", :warning]
      end

    body =
      if address_count > 1000
        "Cette adresse appartient à un grand cluster construit par heuristique multi-input. Cela suggère une activité structurée, sans identifier avec certitude le propriétaire."
      elsif address_count > 20
        "Cette adresse appartient à un cluster significatif construit par heuristique multi-input. Le contexte mérite d’être analysé avant interprétation."
      elsif address_count > 1
        "Cette adresse est liée à d’autres adresses par des transactions multi-input observées."
      else
        "Cette adresse est observée, mais aucun regroupement significatif n’est actuellement affiché."
      end

    {
      title: title,
      body: body,
      tone: tone
    }
  end
end