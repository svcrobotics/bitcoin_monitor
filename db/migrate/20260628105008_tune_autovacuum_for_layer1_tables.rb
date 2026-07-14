class TuneAutovacuumForLayer1Tables < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      ALTER TABLE cluster_inputs SET (
        autovacuum_vacuum_scale_factor = 0.02,
        autovacuum_vacuum_threshold = 5000,
        autovacuum_analyze_scale_factor = 0.01,
        autovacuum_analyze_threshold = 5000
      );

      ALTER TABLE utxo_outputs SET (
        autovacuum_vacuum_scale_factor = 0.02,
        autovacuum_vacuum_threshold = 5000,
        autovacuum_analyze_scale_factor = 0.01,
        autovacuum_analyze_threshold = 5000
      );
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE cluster_inputs RESET (
        autovacuum_vacuum_scale_factor,
        autovacuum_vacuum_threshold,
        autovacuum_analyze_scale_factor,
        autovacuum_analyze_threshold
      );

      ALTER TABLE utxo_outputs RESET (
        autovacuum_vacuum_scale_factor,
        autovacuum_vacuum_threshold,
        autovacuum_analyze_scale_factor,
        autovacuum_analyze_threshold
      );
    SQL
  end
end