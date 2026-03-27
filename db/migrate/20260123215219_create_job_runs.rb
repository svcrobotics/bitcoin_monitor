class CreateJobRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :job_runs do |t|
      t.string :name
      t.string :status
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :duration_ms
      t.integer :exit_code
      t.text :error
      t.text :meta

      t.timestamps
    end
  end
end
