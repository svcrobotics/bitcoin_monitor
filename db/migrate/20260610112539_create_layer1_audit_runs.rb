class CreateLayer1AuditRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :layer1_audit_runs do |t|
      t.integer :audited_height
      t.string :block_hash
      t.string :status
      t.jsonb :checks
      t.jsonb :issues
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end
  end
end
