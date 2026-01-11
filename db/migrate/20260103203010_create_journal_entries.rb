class CreateJournalEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :journal_entries do |t|
      t.datetime :occurred_at
      t.string :kind
      t.string :mood
      t.decimal :btc_price_eur, precision: 16, scale: 2
      t.string :context
      t.text :body
      t.string :tags

      t.timestamps
    end
  end
end
