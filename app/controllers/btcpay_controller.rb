class BtcpayController < ApplicationController
  skip_forgery_protection

  def webhook
    payload  = request.raw_post
    signature = request.headers["BTCPay-Signature"]
    secret   = ENV["BTCPAY_WEBHOOK_SECRET"]

    # 🔐 En production : on vérifie la signature
    if Rails.env.production?
      unless valid_signature?(payload, signature, secret)
        Rails.logger.warn "[BTCPAY] Invalid signature"
        head :unauthorized
        return
      end
    end

    Rails.logger.info "[BTCPAY] Webhook brut: #{payload}"

    data       = JSON.parse(payload) rescue {}
    event      = data["type"]
    invoice_id = data["invoiceId"]

    Rails.logger.info "[BTCPAY] event=#{event} invoice_id=#{invoice_id}"

    feature = FeatureRequest.find_by(btcpay_invoice_id: invoice_id)

    unless feature
      Rails.logger.warn "[BTCPAY] Aucun FeatureRequest pour invoice #{invoice_id}"
      return head :ok
    end

    if ["invoice_paidInFull", "invoice_completed", "invoice_paymentSettled", "InvoiceSettled"].include?(event)
      feature.update!(status: "paid")
      Rails.logger.info "[BTCPAY] FeatureRequest #{feature.id} marqué comme PAID"
    end

    head :ok
  end

  private

  def valid_signature?(payload, signature, secret)
    return false if signature.blank? || secret.blank?

    expected = "sha256=#{OpenSSL::HMAC.hexdigest("sha256", secret, payload)}"
    Rack::Utils.secure_compare(expected, signature)
  end
end
