# db/migrate/XXXXXXXXXXXXXX_add_status_to_trade_simulations.rb
class AddStatusToTradeSimulations < ActiveRecord::Migration[8.0]
  def up
    add_column :trade_simulations, :status, :string, null: false, default: "open"
    add_index  :trade_simulations, :status

    # Backfill: si sell_day existe -> closed, sinon open
    execute <<~SQL
      UPDATE trade_simulations
      SET status = CASE
        WHEN sell_day IS NULL THEN 'open'
        ELSE 'closed'
      END
    SQL

    # Optionnel mais conseillé : buy_day si null -> created_at.to_date
    execute <<~SQL
      UPDATE trade_simulations
      SET buy_day = DATE(created_at)
      WHERE buy_day IS NULL
    SQL
  end

  def down
    remove_index  :trade_simulations, :status
    remove_column :trade_simulations, :status
  end
end
