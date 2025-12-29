require "net/http"
require "uri"
require "json"
require "openssl"

class BtcpayClient
  def initialize
    @host      = ENV.fetch("BTCPAY_HOST")
    @store_id  = ENV.fetch("BTCPAY_STORE_ID")
    @api_key   = ENV.fetch("BTCPAY_API_KEY")

    @uri       = URI.parse(@host)
    @hostname  = @uri.host
    @port      = @uri.port
    @use_ssl   = (@uri.scheme == "https")

    @ip_override      = ENV["BTCPAY_IP"]               # <= 92.129.24.227
    @skip_ssl_verify  = (ENV["BTCPAY_SKIP_SSL_VERIFY"] == "1")
  end

  def create_invoice(amount_sats:, description:, redirect_url:)
    api_uri = URI.parse("#{@host}/api/v1/stores/#{@store_id}/invoices")

    connect_host = @ip_override.presence || api_uri.host

    http = Net::HTTP.new(connect_host, api_uri.port)
    http.use_ssl = @use_ssl
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if @skip_ssl_verify

    req = Net::HTTP::Post.new(api_uri.request_uri)
    req["Host"]          = api_uri.host
    req["Authorization"] = "token #{@api_key}"
    req["Content-Type"]  = "application/json"

    body = {
      amount:   (amount_sats.to_f / 100_000_000),
      currency: "BTC",
      metadata: { description: description },
      checkout: { redirectURL: redirect_url }
    }
    req.body = body.to_json

    res = http.request(req)

    unless res.is_a?(Net::HTTPSuccess)
      Rails.logger.error "[BTCPAY] HTTP #{res.code} – #{res.body}"
      raise "BTCPay error: #{res.code} #{res.body}"
    end

    JSON.parse(res.body)
  end
end
