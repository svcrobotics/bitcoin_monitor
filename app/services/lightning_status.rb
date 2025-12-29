# app/services/lightning_status.rb
require "open3"
require "json"

class LightningStatus
  DEFAULT_CONTAINER = ENV["LND_DOCKER_CONTAINER"] || "btcpayserver_lnd_bitcoin"

  def initialize(container: DEFAULT_CONTAINER)
    @container = container
  end

  def call
    info         = lncli_json(%w[getinfo])
    chan_balance = lncli_json(%w[channelbalance])
    channels     = lncli_json(%w[listchannels])

    return disabled("Impossible de récupérer les infos Lightning (lncli)") unless info && chan_balance

    channels_array = (channels && channels["channels"]) || []

    total_capacity_sat = channels_array.sum { |c| c["capacity"].to_i }
    active_channels    = channels_array.count { |c| c["active"] }
    total_channels     = channels_array.size

    local_sat  = chan_balance.dig("local_balance",  "sat").to_i
    remote_sat = chan_balance.dig("remote_balance", "sat").to_i

    {
      enabled: true,
      error: nil,

      alias: info["alias"],
      pubkey: info["identity_pubkey"],
      num_peers: info["num_peers"].to_i,
      block_height: info["block_height"].to_i,

      num_channels: total_channels,
      active_channels: active_channels,
      capacity_sat: total_capacity_sat,

      local_balance_sat: local_sat,
      remote_balance_sat: remote_sat,

      synced_to_chain: info["synced_to_chain"],
      synced_to_graph: info["synced_to_graph"],
    }
  rescue => e
    disabled(e.message)
  end

  private

  def disabled(message)
    {
      enabled: false,
      error: message,
      alias: nil,
      pubkey: nil,
      num_peers: 0,
      block_height: nil,
      num_channels: 0,
      active_channels: 0,
      capacity_sat: 0,
      local_balance_sat: 0,
      remote_balance_sat: 0,
      synced_to_chain: false,
      synced_to_graph: false,
    }
  end

  # Appelle :
  # docker exec btcpayserver_lnd_bitcoin lncli --macaroonpath=/data/admin.macaroon --tlscertpath=/data/tls.cert <cmd>
  def lncli_json(args)
    base = %w[docker exec]

    cmd = base + [
      @container,
      "lncli",
      "--macaroonpath=/data/admin.macaroon",
      "--tlscertpath=/data/tls.cert"
    ] + args

    stdout, stderr, status = Open3.capture3(cmd.join(" "))

    return nil unless status.success?
    return nil if stdout.strip.empty?

    JSON.parse(stdout)
  rescue JSON::ParserError
    nil
  end
end
