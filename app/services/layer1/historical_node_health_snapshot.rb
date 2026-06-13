# frozen_string_literal: true

module Layer1
  class HistoricalNodeHealthSnapshot
    def self.call
      new.call
    end

    def call
      client = Layer1::HistoricalBitcoinCli.new
      info = client.getblockchaininfo

      {
        module: "historical_node",
        status: "ready",
        datadir: ENV.fetch("BITCOIN_FULL_DATADIR", "/media/victor/bitcoin_archive1/fullnode"),
        blocks: info["blocks"],
        headers: info["headers"],
        verificationprogress: info["verificationprogress"],
        initialblockdownload: info["initialblockdownload"],
        pruned: info["pruned"],
        generated_at: Time.current
      }
    rescue StandardError => e
      {
        module: "historical_node",
        status: "verifying_or_unavailable",
        datadir: ENV.fetch("BITCOIN_FULL_DATADIR", "/media/victor/bitcoin_archive1/fullnode"),
        error: e.message,
        generated_at: Time.current
      }
    end
  end
end
