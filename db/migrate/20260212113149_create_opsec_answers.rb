class CreateOpsecAnswers < ActiveRecord::Migration[7.1]
  def change
    create_table :opsec_answers do |t|
      t.references :opsec_assessment, null: false, foreign_key: true
      t.string  :question_key, null: false
      t.string  :answer, null: false
      t.integer :risk_points, null: false, default: 0

      t.timestamps
    end

    add_index :opsec_answers, :question_key
    add_index :opsec_answers, [:opsec_assessment_id, :question_key], unique: true
  end
end
