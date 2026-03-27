# frozen_string_literal: true

class ClustersController < ApplicationController
  def index
    @clusters_count  = Cluster.count
    @addresses_count = Address.count
    @links_count     = AddressLink.count

    @clusters = Cluster
      .order(address_count: :desc, id: :desc)
      .limit(100)
  end

  def show
    @cluster = Cluster.find(params[:id])
    @metrics = @cluster.cluster_metrics.order(snapshot_date: :desc).limit(7)
    @signals = @cluster.cluster_signals.order(snapshot_date: :desc).limit(10)

    @addresses = @cluster.addresses
      .order(total_sent_sats: :desc, id: :asc)
      .limit(200)

    address_ids = @cluster.addresses.limit(500).pluck(:id)

    @links = AddressLink
      .where(address_a_id: address_ids)
      .or(AddressLink.where(address_b_id: address_ids))
      .order(block_height: :desc, id: :desc)
      .limit(100)
  end
end