class CreateAiInsights < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_insights do |t|
      t.string :key
      t.text :content
      t.string :provider
      t.string :model
      t.string :input_digest
      t.jsonb :meta

      t.timestamps
    end
    add_index :ai_insights, :key
    add_index :ai_insights, :input_digest
  end
end
