class CreateSystemSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :system_snapshots do |t|
      t.string :name, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :captured_at, null: false

      t.timestamps
    end

    add_index :system_snapshots, [:name, :captured_at]
  end
end