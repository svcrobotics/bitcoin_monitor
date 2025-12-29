class CreateWhaleAlerts < ActiveRecord::Migration[8.0]
  def change
    create_table :whale_alerts do |t|
      t.string   :txid, null: false
      t.integer  :block_height
      t.datetime :block_time

      t.decimal :total_out_btc, precision: 16, scale: 8, null: false, default: 0
      t.integer :inputs_count, null: false, default: 0
      t.integer :outputs_count, null: false, default: 0
      t.integer :outputs_nonzero_count, null: false, default: 0

      t.decimal :largest_output_btc, precision: 16, scale: 8, null: false, default: 0
      t.decimal :largest_output_ratio, precision: 6, scale: 4, null: false, default: 0

      t.string  :alert_type, null: false, default: "other"
      t.integer :score, null: false, default: 0
      t.jsonb   :meta, null: false, default: {}

      t.timestamps
    end

    add_index :whale_alerts, :txid, unique: true
    add_index :whale_alerts, :block_height
    add_index :whale_alerts, :block_time
    add_index :whale_alerts, :alert_type
    add_index :whale_alerts, :score
  end
end
