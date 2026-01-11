class TradeSimulationsController < ApplicationController
  before_action :set_trade_simulation, only: %i[ show edit update destroy ]

  # GET /trade_simulations or /trade_simulations.json
  def index
    @trade_simulations = TradeSimulation.all
  end

  # GET /trade_simulations/1 or /trade_simulations/1.json
  def show
    # 1) Toujours générer / compléter les points (ne dépend pas de sell_day)
    TradeSimulationCurveBuilder.call(@trade_simulation)
    @points = @trade_simulation.points.order(:day)

    # 2) Séries du graphique (même si @result est nil)
    @combo_series = []
    if @points.present?
      @combo_series << {
        name: "Net (USD)",
        data: @points.map { |p| [p.day.to_s, p.net_usd.to_f.round(2)] },
        yAxisID: "y"
      }
      @combo_series << {
        name: "PnL (%)",
        data: @points.map { |p| [p.day.to_s, p.pnl_pct.to_f.round(2)] },
        yAxisID: "y1"
      }
    end

    # 3) Calcul “résultat” pour la date de vente choisie dans la simulation
    @result = TradeSimulator.call(@trade_simulation)

  rescue TradeSimulator::PriceMissing => e
    flash.now[:alert] = e.message
    @result = nil
  end

  # GET /trade_simulations/new
  def new
    @trade_simulation = TradeSimulation.new
  end

  # GET /trade_simulations/1/edit
  def edit
  end

  # POST /trade_simulations or /trade_simulations.json
  def create
    @trade_simulation = TradeSimulation.new(trade_simulation_params)

    respond_to do |format|
      if @trade_simulation.save
        format.html { redirect_to @trade_simulation, notice: "Trade simulation was successfully created." }
        format.json { render :show, status: :created, location: @trade_simulation }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @trade_simulation.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /trade_simulations/1 or /trade_simulations/1.json
  def update
    respond_to do |format|
      if @trade_simulation.update(trade_simulation_params)
        format.html { redirect_to @trade_simulation, notice: "Trade simulation was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @trade_simulation }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @trade_simulation.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /trade_simulations/1 or /trade_simulations/1.json
  def destroy
    @trade_simulation.destroy!

    respond_to do |format|
      format.html { redirect_to trade_simulations_path, notice: "Trade simulation was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_trade_simulation
      @trade_simulation = TradeSimulation.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def trade_simulation_params
      params.expect(trade_simulation: [ :buy_day, :sell_day, :btc_amount, :buy_fee_pct, :buy_fee_fixed_eur, :sell_fee_pct, :sell_fee_fixed_eur, :slippage_pct, :notes ])
    end
end
