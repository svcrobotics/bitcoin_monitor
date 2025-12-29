# app/controllers/btcpay_webhooks_controller.rb
class BtcpayWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def receive
    payload = JSON.parse(request.raw_post)

    Rails.logger.info("[BTCPAY] Webhook reçu")
    Rails.logger.info(payload.inspect)

    event_type = payload["type"]
    invoice_id = payload.dig("invoiceId") || payload.dig("invoice", "id")

    unless invoice_id
      Rails.logger.warn("[BTCPAY] invoiceId manquant")
      head :ok
      return
    end

    feature_request = FeatureRequest.find_by(btcpay_invoice_id: invoice_id)

    unless feature_request
      Rails.logger.warn("[BTCPAY] FeatureRequest introuvable pour invoice #{invoice_id}")
      head :ok
      return
    end

    case event_type
    when "InvoiceProcessing"
      feature_request.update(status: "awaiting_payment")

    when "InvoiceSettled", "InvoicePaymentSettled"
      feature_request.update(status: "paid")

    when "InvoiceExpired"
      feature_request.update(status: "expired")

    when "InvoiceInvalid"
      feature_request.update(status: "invalid")
    end

    head :ok
  rescue JSON::ParserError
    Rails.logger.error("[BTCPAY] JSON invalide")
    head :bad_request
  rescue => e
    Rails.logger.error("[BTCPAY] ERREUR #{e.class} #{e.message}")
    head :internal_server_error
  end
end
