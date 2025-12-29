class RenameValidInBrc20Events < ActiveRecord::Migration[8.0]
  def change
    rename_column :brc20_events, :valid, :is_valid
  end
end
