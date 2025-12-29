
class CreateRuneBlockStats < ActiveRecord::Migration[8.0]
  def change
    create_table :rune_block_stats do |t|
      t.integer  :block_height, null: false
      t.datetime :block_time

      # Nombre de transactions contenant des Runes
      t.integer :rune_tx_count,        null: false, default: 0
      # Nombre total d'évènements Runes (etch + mint + transfer + burn)
      t.integer :rune_events_count,    null: false, default: 0
      # Nombre de runes distinctes touchées dans ce bloc
      t.integer :distinct_runes_count, null: false, default: 0

      # Volume total de Runes déplacées (toutes runes confondues)
      t.decimal :total_runes_volume, precision: 39, scale: 0, null: false, default: 0

      # Optionnel : estimation de l’empreinte Runes en octets
      t.bigint :total_runes_bytes, null: false, default: 0

      t.timestamps
    end

    add_index :rune_block_stats, :block_height, unique: true
  end
end
