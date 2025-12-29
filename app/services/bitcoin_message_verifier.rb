# app/services/bitcoin_message_verifier.rb
require "open3"

class BitcoinMessageVerifier
  class << self
    def verify(address:, message:, signature:)
      addr = address.to_s.strip
      sig  = signature.to_s.strip
      msg  = message.to_s.rstrip

      return false if addr.empty? || sig.empty? || msg.empty?

      stdout = run_bitcoin_cli("verifymessage", addr, sig, msg)
      stdout.strip == "true"
    rescue => e
      Rails.logger.warn("[BitcoinMessageVerifier] #{e.class}: #{e.message}")
      false
    end

    private

    def run_bitcoin_cli(*args)
      datadir = ENV.fetch("BITCOIN_DATADIR", "/mnt/bitcoin")
      cmd = ["bitcoin-cli", "-datadir=#{datadir}", *args]

      Rails.logger.info("[BitcoinMessageVerifier] #{cmd.inspect}")

      stdout, stderr, status = Open3.capture3(*cmd)
      Rails.logger.warn("[BitcoinMessageVerifier] STDERR: #{stderr}") if stderr.present?
      raise "bitcoin-cli failed" unless status.success?

      stdout
    end
  end
end
