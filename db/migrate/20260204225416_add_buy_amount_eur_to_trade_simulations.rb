class AddBuyAmountEurToTradeSimulations < ActiveRecord::Migration[8.0]
  def change
    add_column :trade_simulations, :buy_amount_eur, :decimal, precision: 20, scale: 8
  end
end
