# app/controllers/trade_simulations_controller.rb
class TradeSimulationsController < ApplicationController
  before_action :set_trade_simulation, only: %i[show edit update destroy close close_update]

  def index
    @trade_simulations = TradeSimulation.order(created_at: :desc)
  end

  def show
    TradeSimulationCurveBuilder.call(@trade_simulation)
    @points = @trade_simulation.points.order(:day)

    @pnl_info = nil
    if @points.present?
      last  = @points.last
      best  = @points.max_by { |p| p.pnl_pct.to_f }
      worst = @points.min_by { |p| p.pnl_pct.to_f }

      @pnl_info = {
        last_day: last.day,
        last_net: last.net_usd.to_f,
        last_pnl_pct: last.pnl_pct.to_f,
        best_day: best.day,
        best_pnl_pct: best.pnl_pct.to_f,
        worst_day: worst.day,
        worst_pnl_pct: worst.pnl_pct.to_f
      }
    end

    @combo_series = []
    if @points.present?
      @combo_series << { name: "Net (EUR)", data: @points.map { |p| [p.day.to_s, p.net_usd.to_f.round(2)] } }
      @combo_series << { name: "PnL (%)",  data: @points.map { |p| [p.day.to_s, p.pnl_pct.to_f.round(2)] } }
    end

    # Résultat final uniquement si clôturée
    @result = @trade_simulation.closed? ? TradeSimulator.call(@trade_simulation) : nil

    @preview_sell_today = nil
    @preview_sell_today_mirror = nil

    if @trade_simulation.open?
      last_day = BtcPriceDay.where.not(close_eur: nil).maximum(:day)

      if last_day.present?
        # Preview avec frais de vente actuels
        sim_a = @trade_simulation.dup
        sim_a.sell_day = last_day
        @preview_sell_today = TradeSimulator.call(sim_a)

        # Option A: frais de vente = frais d’achat
        sim_b = @trade_simulation.dup
        sim_b.sell_day = last_day
        sim_b.sell_fee_pct = @trade_simulation.buy_fee_pct
        sim_b.sell_fee_fixed_eur = @trade_simulation.buy_fee_fixed_eur
        @preview_sell_today_mirror = TradeSimulator.call(sim_b)
      end
    end

    # ------------------------------------------------------------
    # Aperçu "si je vends aujourd'hui" (dernier close_eur dispo)
    # ------------------------------------------------------------
    @preview_sell_today = nil
    @preview_sell_today_mirror = nil

    if @trade_simulation.open?
      last_day = BtcPriceDay.where.not(close_eur: nil).maximum(:day)

      if last_day.present?
        # A) preview avec les frais de vente actuels
        sim_a = @trade_simulation.dup
        sim_a.sell_day = last_day
        @preview_sell_today = TradeSimulator.call(sim_a)

        # B) preview "frais vente = frais achat"
        sim_b = @trade_simulation.dup
        sim_b.sell_day = last_day
        sim_b.sell_fee_pct = @trade_simulation.buy_fee_pct
        sim_b.sell_fee_fixed_eur = @trade_simulation.buy_fee_fixed_eur
        @preview_sell_today_mirror = TradeSimulator.call(sim_b)
      end
    end

  rescue TradeSimulator::PriceMissing => e
    flash.now[:alert] = e.message
    @result = nil
    @preview_sell_today = nil
    @preview_sell_today_mirror = nil
  end

  def new
    @trade_simulation = TradeSimulation.new
  end

  def edit
    redirect_to @trade_simulation, alert: "Simulation clôturée : modification interdite." if @trade_simulation.closed?
  end

  # OUVERTURE (BUY)
  def create
    @trade_simulation = TradeSimulation.new(trade_simulation_open_params)
    @trade_simulation.status = "open"
    @trade_simulation.sell_day = nil

    respond_to do |format|
      if @trade_simulation.save
        format.html { redirect_to @trade_simulation, notice: "Position ouverte ✅" }
        format.json { render :show, status: :created, location: @trade_simulation }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @trade_simulation.errors, status: :unprocessable_entity }
      end
    end
  end

  # UPDATE BUY (uniquement si open)
  def update
    if @trade_simulation.closed?
      respond_to do |format|
        format.html { redirect_to @trade_simulation, alert: "Simulation clôturée : modification interdite." }
        format.json { render json: { error: "closed" }, status: :unprocessable_entity }
      end
      return
    end

    respond_to do |format|
      if @trade_simulation.update(trade_simulation_open_params)
        format.html { redirect_to @trade_simulation, notice: "Simulation mise à jour.", status: :see_other }
        format.json { render :show, status: :ok, location: @trade_simulation }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @trade_simulation.errors, status: :unprocessable_entity }
      end
    end
  end

  def close
    redirect_to @trade_simulation, notice: "Déjà clôturée." if @trade_simulation.closed?
  end

  # CLOTURE (SELL)
  def close_update
    if @trade_simulation.closed?
      redirect_to @trade_simulation, notice: "Déjà clôturée."
      return
    end

    respond_to do |format|
      if @trade_simulation.update(trade_simulation_close_params.merge(status: "closed"))
        format.html { redirect_to @trade_simulation, notice: "Position clôturée ✅", status: :see_other }
        format.json { render :show, status: :ok, location: @trade_simulation }
      else
        format.html { render :close, status: :unprocessable_entity }
        format.json { render json: @trade_simulation.errors, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    @trade_simulation.destroy!
    respond_to do |format|
      format.html { redirect_to trade_simulations_path, notice: "Trade simulation supprimée.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private

  def set_trade_simulation
    @trade_simulation = TradeSimulation.find(params[:id])
  end

  # BUY params
  def trade_simulation_open_params
    params.require(:trade_simulation).permit(
      :buy_day,
      :buy_amount_eur,
      :buy_fee_pct, :buy_fee_fixed_eur,
      :slippage_pct,
      :notes
    )
  end

  # SELL params
  def trade_simulation_close_params
    params.require(:trade_simulation).permit(
      :sell_day,
      :sell_fee_pct, :sell_fee_fixed_eur
    )
  end
end
