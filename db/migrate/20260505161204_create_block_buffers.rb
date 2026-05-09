class CreateBlockBuffers < ActiveRecord::Migration[8.0]
  def change
    create_table :block_buffers do |t|
      # identité du bloc
      t.integer :height, null: false
      t.string  :hash, null: false
      t.string  :previous_hash

      # metadata utile pipeline
      t.integer :tx_count
      t.integer :size_bytes

      # état du pipeline
      t.string :status, null: false, default: "pending"
      # pending -> processing -> processed -> failed

      # timestamps blockchain (optionnel mais utile debug)
      t.datetime :block_time

      t.timestamps
    end

    # 🔥 contraintes critiques
    add_index :block_buffers, :hash, unique: true
    add_index :block_buffers, :height, unique: true
    add_index :block_buffers, :status
    add_index :block_buffers, [:height, :status]
  end
end