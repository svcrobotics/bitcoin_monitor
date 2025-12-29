class FeatureRequestsController < ApplicationController
  before_action :set_feature_request, only: %i[show edit update destroy generate_invoice]

  def index
    @feature_requests = FeatureRequest.order(created_at: :desc)
  end

  def show
  end

  def new
    @feature_request = FeatureRequest.new
  end

  def create
    @feature_request = FeatureRequest.new(feature_request_params)
    @feature_request.status = "pending"

    if @feature_request.save
      redirect_to @feature_request, notice: "Demande enregistrée !"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @feature_request.update(feature_request_params)
      redirect_to @feature_request, notice: "Demande mise à jour."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @feature_request.destroy
    redirect_to feature_requests_path, notice: "Demande supprimée."
  end

  def generate_invoice
    if @feature_request.amount_sats.to_i <= 0
      redirect_to @feature_request, alert: "Montant en sats invalide."
      return
    end

    client = BtcpayClient.new

    invoice = client.create_invoice(
      amount_sats: @feature_request.amount_sats,
      description: "Amélioration : #{@feature_request.title}",
      redirect_url: feature_request_url(@feature_request)
    )

    @feature_request.update!(
      btcpay_invoice_id:   invoice["id"],
      btcpay_checkout_url: invoice["checkoutLink"],
      status:              "awaiting_payment"
    )

    redirect_to @feature_request
  rescue => e
    Rails.logger.error("[BTCPAY] #{e.class} #{e.message}")
    redirect_to @feature_request, alert: "Erreur BTCPay (#{e.class}) : #{e.message}"
  end

  private

  def set_feature_request
    @feature_request = FeatureRequest.find(params[:id])
  end

  def feature_request_params
    params.require(:feature_request).permit(:title, :description, :email, :amount_sats, :status)
  end
end
