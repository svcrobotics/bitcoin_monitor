# frozen_string_literal: true

class AddressLookupController < ApplicationController
  RETAIL_STRUCTURED_CLUSTER_SIZE = 50
  RETAIL_STRUCTURED_TOTAL_SENT_BTC = 500.0

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
      @cluster_profile = nil
      @user_message = nil
      @cluster_label = nil
      @cluster_tone = :neutral
      @cluster_signals = []
      @linked_addresses = []
      @links = []
      return
    end

    @observed = true
    @cluster = @address_record.cluster
    @cluster_profile = @cluster&.cluster_profile
    @cluster_total_sent_sats = @cluster.present? ? @cluster.addresses.sum(:total_sent_sats) : 0
    @cluster_metric = @cluster&.cluster_metrics&.order(snapshot_date: :desc, id: :desc)&.first

    latest_signal_date = @cluster&.cluster_signals&.maximum(:snapshot_date)

    @cluster_signals =
      if @cluster.present? && latest_signal_date.present?
        @cluster.cluster_signals
          .where(snapshot_date: latest_signal_date)
          .order(score: :desc, id: :desc)
          .limit(5)
      else
        []
      end

    @user_message = build_user_message(
      cluster: @cluster,
      cluster_profile: @cluster_profile,
      cluster_signals: @cluster_signals
    )

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

  def build_user_message(cluster:, cluster_profile:, cluster_signals:)
    return nil unless cluster_profile.present?

    if cluster_profile.present? && cluster.present?
      addr_total = cluster.addresses.maximum(:total_sent_sats).to_i
      cluster_total = cluster_profile.total_sent_sats.to_i

      if addr_total > cluster_total
        return {
          title: "Cluster incomplet ou en cours de construction",
          body: "Le volume observé sur une adresse dépasse l’agrégat du cluster. Certaines adresses liées peuvent ne pas être encore identifiées.",
          tone: :info
        }
      end
    end

    classification = cluster_profile.classification.to_s
    score = cluster_profile.score.to_i
    traits = Array(cluster_profile.traits).map(&:to_s)

    cluster_size = cluster&.address_count.to_i
    total_sent_sats = cluster_profile.total_sent_sats.to_i
    total_sent_btc = total_sent_sats / 100_000_000.0

    signals = Array(cluster_signals)
    high_signal_present = signals.any? { |signal| signal.severity.to_s == "high" }
    signal_types = signals.map { |signal| signal.signal_type.to_s }

    structured_retail =
      classification == "retail" && (
        cluster_size >= RETAIL_STRUCTURED_CLUSTER_SIZE ||
        total_sent_btc >= RETAIL_STRUCTURED_TOTAL_SENT_BTC ||
        high_signal_present ||
        traits.include?("high_volume") ||
        traits.include?("whale_like") ||
        signal_types.include?("large_transfers") ||
        signal_types.include?("volume_spike")
      )

    if structured_retail
      return {
        title: "Cluster utilisateur à activité significative",
        body: "Adresse classée côté utilisateur, mais rattachée à un cluster présentant un volume ou une activité récents compatibles avec un acteur structuré. Vérification recommandée avant envoi.",
        tone: :warning
      }
    end

    title =
      case classification
      when "exchange_like", "service"
        "Adresse liée à une plateforme probable"
      when "whale"
        "Adresse liée à un acteur important"
      when "retail"
        "Adresse liée à un utilisateur individuel"
      else
        "Adresse observée sur le réseau"
      end

    risk =
      if traits.include?("high_volume") || traits.include?("whale_like")
        :warning
      elsif score >= 80
        :info
      else
        :neutral
      end

    tone =
      case risk
      when :warning then :warning
      when :info    then :info
      else :neutral
      end

    parts = []
    parts << "cluster de grande taille" if traits.include?("large_cluster")
    parts << "activité élevée" if traits.include?("high_activity")
    parts << "volume important" if traits.include?("high_volume")
    parts << "activité compatible avec des volumes institutionnels" if traits.include?("whale_like")

    description =
      if parts.any?
        parts.join(", ")
      else
        "activité on-chain observée"
      end

    recommendation =
      case risk
      when :warning
        "Vérification recommandée avant envoi."
      when :info
        "Contexte actif, analyse recommandée."
      else
        "Aucune alerte particulière détectée."
      end

    body = "#{description.capitalize}. #{recommendation}"

    {
      title: title,
      body: body,
      tone: tone
    }
  end
end
