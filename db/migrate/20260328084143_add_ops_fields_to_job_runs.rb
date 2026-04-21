class AddOpsFieldsToJobRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :job_runs, :heartbeat_at, :datetime
    add_column :job_runs, :triggered_by, :string
    add_column :job_runs, :scheduled_for, :datetime

    add_index :job_runs, :heartbeat_at
    add_index :job_runs, :triggered_by
    add_index :job_runs, :scheduled_for
    add_index :job_runs, [:name, :status, :started_at]
  end
end