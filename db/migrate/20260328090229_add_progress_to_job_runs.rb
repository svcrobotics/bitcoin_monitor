class AddProgressToJobRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :job_runs, :progress_pct, :float
    add_column :job_runs, :progress_label, :string
    add_column :job_runs, :progress_meta, :jsonb
  end
end
