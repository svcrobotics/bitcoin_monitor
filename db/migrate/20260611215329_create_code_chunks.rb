class CreateCodeChunks < ActiveRecord::Migration[8.0]
  def change
    enable_extension "vector" unless extension_enabled?("vector")

    create_table :code_chunks do |t|
      t.string :path, null: false
      t.integer :chunk_index, null: false, default: 0
      t.text :content, null: false
      t.string :content_hash, null: false
      t.vector :embedding, limit: 1536

      t.timestamps
    end

    add_index :code_chunks, [:path, :chunk_index], unique: true
    add_index :code_chunks, :content_hash
  end
end