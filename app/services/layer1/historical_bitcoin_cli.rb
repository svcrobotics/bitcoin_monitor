# frozen_string_literal: true

require "json"
require "open3"

module Layer1
  class HistoricalBitcoinCli
    DEFAULT_DATADIR = "/media/victor/bitcoin_archive1/fullnode"

    def self.call(*args)
      new.call(*args)
    end

    def initialize(datadir: nil)
      @datadir = datadir.presence || ENV.fetch("BITCOIN_FULL_DATADIR", DEFAULT_DATADIR)
    end

    def call(*args)
      command = ["bitcoin-cli", "-datadir=#{@datadir}", *args.map(&:to_s)]

      stdout, stderr, status = Open3.capture3(*command)

      unless status.success?
        raise Error, "bitcoin-cli historical failed: #{stderr.presence || stdout}"
      end

      stdout
    end

    def getblockchaininfo
      JSON.parse(call("getblockchaininfo"))
    end

    def getblockhash(height)
      call("getblockhash", height).strip
    end

    def getblock(hash_or_height, verbosity = 2)
      hash =
        if hash_or_height.to_s.match?(/\A\d+\z/)
          getblockhash(hash_or_height)
        else
          hash_or_height.to_s
        end

      JSON.parse(call("getblock", hash, verbosity))
    end

    def ready?
      getblockchaininfo
      true
    rescue StandardError
      false
    end

    class Error < StandardError; end
  end
end
