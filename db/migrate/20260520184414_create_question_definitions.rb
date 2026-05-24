class CreateQuestionDefinitions < ActiveRecord::Migration[8.0]
  def change
    create_table :question_definitions do |t|
      t.string :key, null: false
      t.string :module_name, null: false
      t.string :tier, null: false
      t.text :question, null: false
      t.string :intent, null: false
      t.string :answer_service, null: false
      t.string :historical_path
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :question_definitions, :key, unique: true
    add_index :question_definitions, :module_name
    add_index :question_definitions, :tier
    add_index :question_definitions, :intent
    add_index :question_definitions, :active
    add_index :question_definitions, [:module_name, :tier, :position]
  end
end