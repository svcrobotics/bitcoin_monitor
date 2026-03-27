class CreateOpsecAssessments < ActiveRecord::Migration[7.1]
  def change
    create_table :opsec_assessments do |t|
      t.integer :score, null: false, default: 0
      t.string  :risk_level, null: false, default: "yellow"
      t.integer :total_risk_points, null: false, default: 0
      t.integer :max_risk_points, null: false, default: 0

      t.timestamps
    end

    add_index :opsec_assessments, :risk_level
  end
end
