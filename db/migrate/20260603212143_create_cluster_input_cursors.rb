class CreateClusterInputCursors < ActiveRecord::Migration[8.0]
  def change
    create_table :cluster_input_cursors do |t|
      t.integer :last_height_processed

      t.timestamps
    end
  end
end
