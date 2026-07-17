# frozen_string_literal: true

module ClusterTransactionProjection
  class BackfillRunner
    OWNER = "cluster_transaction_projection"
    DEFAULT_CHUNK_SIZE = 50_000
    MIN_FREE_BYTES = 25.gigabytes
    MAX_PILOT_BYTES = 2.gigabytes

    SOURCE_STAGES = {
      "cluster_inputs_received" => {
        table: "cluster_inputs",
        txid_column: "txid",
        height_column: "block_height",
        fact_column: "received_height"
      },
      "utxo_outputs_received" => {
        table: "utxo_outputs",
        txid_column: "txid",
        height_column: "block_height",
        fact_column: "received_height"
      },
      "cluster_inputs_spent" => {
        table: "cluster_inputs",
        txid_column: "spent_txid",
        height_column: "spent_block_height",
        fact_column: "spent_height"
      }
    }.freeze

    STAGES = ClusterTransactionProjectionBackfillItem::STAGES

    class StaleRunError < StandardError; end

    def self.create_run!(...)
      new(...).create_run!
    end

    def self.plan!(...)
      new(...).plan!
    end

    def self.call(...)
      new(...).call
    end

    def initialize(
      cluster_ids: nil,
      run_id: nil,
      target_checkpoint_height:,
      target_checkpoint_hash:,
      source: "pilot_backfill",
      chunk_size: DEFAULT_CHUNK_SIZE,
      max_chunks: nil,
      pause_after_chunks: nil,
      stop_after_chunks: nil,
      budget_seconds: nil,
      min_chunk_margin_seconds: 5,
      min_free_bytes: MIN_FREE_BYTES,
      max_pilot_bytes: MAX_PILOT_BYTES,
      external_lease: nil,
      preemption_check: nil,
      logger: Rails.logger
    )
      @cluster_ids = Array(cluster_ids).map(&:to_i).uniq.sort
      @run_id = run_id
      @target_checkpoint_height = target_checkpoint_height.to_i
      @target_checkpoint_hash = target_checkpoint_hash.to_s
      @source = source.to_s
      @chunk_size = chunk_size.to_i
      @max_chunks = max_chunks&.to_i
      @pause_after_chunks = pause_after_chunks&.to_i
      @stop_after_chunks = stop_after_chunks&.to_i
      @budget_seconds = budget_seconds&.to_i
      @min_chunk_margin_seconds = min_chunk_margin_seconds.to_i
      @min_free_bytes = min_free_bytes.to_i
      @max_pilot_bytes = max_pilot_bytes.to_i
      @external_lease = external_lease
      @preemption_check = preemption_check
      @logger = logger
      @chunks_processed = 0
      @rows_scanned = 0
      @facts_inserted = 0
      @facts_updated = 0
      @last_chunk_ms = nil
      @started_at = nil
      @lease = nil
    end

    def call
      @started_at =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        )

      run =
        run_id.present? ?
          ClusterTransactionProjectionBackfillRun.find(run_id) :
          plan!

      acquire_lease!

      begin
        prepare_run!(run)

        run.update!(
          status: "running",
          started_at: run.started_at || Time.current,
          paused_at: nil,
          last_error: nil
        )

        loop do
          return finish_run!(run) if all_items_certified?(run)
          return pause_run!(run, :max_chunks) if max_chunks_reached?
          return pause_run!(run, :pause_requested) if pause_after_chunks_reached?
          return stop_after_chunk!(run) if stop_after_chunks_reached?
          return pause_run!(run, :budget_exhausted) if budget_prevents_next_chunk?

          preemption_reason = preemption_reason(run)
          return pause_run!(run, preemption_reason) if preemption_reason

          item = next_item(run)
          return finish_run!(run) unless item

          process_item_step!(run, item)
          @chunks_processed += 1
          renew_lease!
        end
      rescue StaleRunError => error
        run.update!(
          status: "stale",
          stale_at: Time.current,
          stale_reason: error.message,
          last_error: error.message
        )
        raise
      rescue => error
        run.update!(
          status: "failed",
          last_error: "#{error.class}: #{error.message}"
        )
        raise
      ensure
        release_lease unless external_lease?
      end
    end

    def create_run!
      plan!
    end

    def plan!
      ClusterTransactionProjection::BackfillPlanner.plan!(
        cluster_ids: cluster_ids,
        target_checkpoint_height: target_checkpoint_height,
        target_checkpoint_hash: target_checkpoint_hash,
        source: source
      )
    end

    private

    attr_reader(
      :cluster_ids,
      :run_id,
      :target_checkpoint_height,
      :target_checkpoint_hash,
      :source,
      :chunk_size,
      :max_chunks,
      :pause_after_chunks,
      :stop_after_chunks,
      :budget_seconds,
      :min_chunk_margin_seconds,
      :min_free_bytes,
      :max_pilot_bytes,
      :external_lease,
      :preemption_check,
      :logger
    )

    def process_item_step!(run, item)
      verify_target_checkpoint!
      verify_disk_limits!
      verify_item_composition!(item)

      item.update!(
        status: "building",
        started_at: item.started_at || Time.current,
        last_error: nil
      ) if item.status.in?(%w[pending paused])

      if SOURCE_STAGES.key?(item.stage)
        process_source_chunk!(run, item)
      elsif item.stage == "counter_audit"
        perform_counter_audit!(item)
      elsif item.stage == "certification"
        certify_item!(item)
      else
        raise ArgumentError, "unknown backfill stage #{item.stage.inspect}"
      end
    end

    def process_source_chunk!(run, item)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stage_config = SOURCE_STAGES.fetch(item.stage)
      stage_items = source_stage_items(run, item.stage)
      cursors = stage_items.map { |stage_item| stage_item.cursor_for(item.stage) }.uniq
      raise "divergent source cursors for #{item.stage}" if cursors.size > 1

      stage_items.each do |stage_item|
        next if stage_item.status == "building"

        stage_item.update!(
          status: "building",
          started_at: stage_item.started_at || Time.current,
          last_error: nil
        )
      end

      cursor = cursors.first.to_i
      upper = next_upper_cursor(stage_config, cursor)

      if upper.fetch(:rows_scanned).zero?
        stage_items.each { |stage_item| advance_stage!(stage_item) }
        return
      end

      counts =
        upsert_stage_facts!(
          run: run,
          items: stage_items,
          stage_config: stage_config,
          stage: item.stage,
          cursor: cursor,
          upper_id: upper.fetch(:upper_id)
        )

      duration_ms =
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      stage_items.each do |stage_item|
        item_counts =
          counts.fetch(
            stage_item.projection_generation_id,
            { inserted: 0, updated: 0 }
          )

        update_chunk_metrics!(
          stage_item,
          stage: item.stage,
          cursor_start: cursor,
          cursor_end: upper.fetch(:upper_id),
          rows_scanned: upper.fetch(:rows_scanned),
          inserted: item_counts.fetch(:inserted),
          updated: item_counts.fetch(:updated),
          duration_ms: duration_ms
        )
      end
    end

    def next_upper_cursor(stage_config, cursor)
      table = stage_config.fetch(:table)
      height_column = stage_config.fetch(:height_column)
      txid_column = stage_config.fetch(:txid_column)

      sql = sanitize(
        <<~SQL.squish,
          SELECT
            COALESCE(MAX(id), 0) AS upper_id,
            COUNT(*) AS rows_scanned
          FROM (
            SELECT id
            FROM #{table}
            WHERE id > :cursor
              AND #{height_column} IS NOT NULL
              AND #{height_column} <= :checkpoint
              AND #{txid_column} IS NOT NULL
            ORDER BY id ASC
            LIMIT :limit
          ) source_ids
        SQL
        cursor: cursor,
        checkpoint: target_checkpoint_height,
        limit: chunk_size
      )

      row = ActiveRecord::Base.connection.select_one(sql)

      {
        upper_id: row.fetch("upper_id").to_i,
        rows_scanned: row.fetch("rows_scanned").to_i
      }
    end

    def upsert_stage_facts!(run:, items:, stage_config:, stage:, cursor:, upper_id:)
      table = stage_config.fetch(:table)
      txid_column = stage_config.fetch(:txid_column)
      height_column = stage_config.fetch(:height_column)
      fact_column = stage_config.fetch(:fact_column)
      other_fact_column =
        fact_column == "received_height" ? "spent_height" : "received_height"
      generation_ids = items.map(&:projection_generation_id)

      sql = sanitize(
        <<~SQL.squish,
          WITH source_chunk AS MATERIALIZED (
            SELECT
              id,
              address,
              #{txid_column} AS txid_hex,
              #{height_column} AS fact_height
            FROM #{table}
            WHERE id > :cursor
              AND id <= :upper_id
              AND #{height_column} IS NOT NULL
              AND #{height_column} <= :checkpoint
              AND #{txid_column} IS NOT NULL
              AND #{txid_column} ~ '^[0-9A-Fa-f]{64}$'
          ),
          activity AS (
            SELECT
              items.projection_generation_id,
              source.txid_hex,
              MIN(source.fact_height) AS fact_height
            FROM source_chunk source
            INNER JOIN cluster_transaction_projection_backfill_addresses active
              ON active.run_id = :run_id
             AND active.address = source.address
            INNER JOIN cluster_transaction_projection_backfill_items items
              ON items.run_id = active.run_id
             AND items.cluster_id = active.cluster_id
             AND items.stage = :stage
             AND items.status IN ('pending', 'building', 'paused')
             AND items.projection_generation_id IN (:generation_ids)
            GROUP BY items.projection_generation_id, source.txid_hex
          ),
          upserted AS (
            INSERT INTO cluster_transaction_facts (
              projection_generation_id,
              txid,
              #{fact_column},
              created_at,
              updated_at
            )
            SELECT
              activity.projection_generation_id,
              decode(activity.txid_hex, 'hex'),
              activity.fact_height,
              CURRENT_TIMESTAMP,
              CURRENT_TIMESTAMP
            FROM activity
            ON CONFLICT (projection_generation_id, txid)
            DO UPDATE SET
              #{fact_column} =
                CASE
                  WHEN cluster_transaction_facts.#{fact_column} IS NULL
                    THEN EXCLUDED.#{fact_column}
                  WHEN EXCLUDED.#{fact_column} IS NULL
                    THEN cluster_transaction_facts.#{fact_column}
                  ELSE LEAST(
                    cluster_transaction_facts.#{fact_column},
                    EXCLUDED.#{fact_column}
                  )
                END,
              #{other_fact_column} =
                cluster_transaction_facts.#{other_fact_column},
              updated_at = EXCLUDED.updated_at
            RETURNING projection_generation_id, (xmax = 0) AS inserted
          )
          SELECT
            projection_generation_id,
            COUNT(*) FILTER (WHERE inserted) AS inserted,
            COUNT(*) FILTER (WHERE NOT inserted) AS updated
          FROM upserted
          GROUP BY projection_generation_id
        SQL
        run_id: run.id,
        stage: stage,
        generation_ids: generation_ids,
        cursor: cursor,
        upper_id: upper_id,
        checkpoint: target_checkpoint_height
      )

      ActiveRecord::Base.connection.select_all(sql).each_with_object({}) do |row, memo|
        memo[row.fetch("projection_generation_id").to_i] = {
          inserted: row.fetch("inserted").to_i,
          updated: row.fetch("updated").to_i
        }
      end
    end

    def perform_counter_audit!(item)
      generation = item.projection_generation
      counts = CounterAudit.compute_counts(generation)

      generation.update!(
        inflow_count: counts.fetch(:inflow_count),
        outflow_count: counts.fetch(:outflow_count),
        tx_count: counts.fetch(:tx_count),
        facts_count: counts.fetch(:facts_count)
      )

      update_chunk_metrics!(
        item,
        stage: item.stage,
        cursor_start: 0,
        cursor_end: 0,
        rows_scanned: 0,
        inserted: 0,
        updated: 0,
        duration_ms: 0,
        extra: counts
      )

      item.update!(
        status: "ready_to_certify",
        stage: "certification"
      )
    end

    def certify_item!(item)
      verify_item_composition!(item)
      verify_target_checkpoint!

      generation = item.projection_generation
      audit = CounterAudit.call(generation)
      raise "counter audit mismatch for cluster #{item.cluster_id}" unless audit.ok

      ensure_projection_anchor_block!

      result = Certifier.call(generation)
      raise "certification refused #{result.reason}" unless result.ok

      item.update!(
        status: "certified",
        completed_at: Time.current,
        last_error: nil
      )
    end

    def ensure_projection_anchor_block!
      block =
        ClusterTransactionProjectionBlock
          .lock
          .find_or_initialize_by(block_height: target_checkpoint_height)

      if block.persisted? &&
         block.status == "projected" &&
         block.block_hash != target_checkpoint_hash
        raise "projection anchor hash mismatch"
      end

      block.update!(
        block_hash: target_checkpoint_hash,
        status: "projected",
        completed_at: block.completed_at || Time.current,
        last_error: nil
      )
    end

    def advance_stage!(item)
      next_stage = STAGES[STAGES.index(item.stage) + 1]
      raise "no next stage for #{item.stage}" unless next_stage

      item.update!(
        stage: next_stage,
        status: next_stage == "certification" ? "ready_to_certify" : "building"
      )
    end

    def update_chunk_metrics!(
      item,
      stage:,
      cursor_start:,
      cursor_end:,
      rows_scanned:,
      inserted:,
      updated:,
      duration_ms:,
      extra: {}
    )
      metrics = item.metrics.deep_dup
      chunks = Array(metrics["chunks"])
      chunks << {
        "stage" => stage,
        "cursor_start" => cursor_start,
        "cursor_end" => cursor_end,
        "rows_scanned" => rows_scanned,
        "facts_inserted" => inserted,
        "facts_updated" => updated,
        "duration_ms" => duration_ms,
        "disk_free_bytes" => disk_free_bytes,
        "projection_bytes" => projection_bytes,
        "strict_io_owner" => @lease&.owner,
        "strict_io_token" => @lease&.token,
        "recorded_at" => Time.current.iso8601(6)
      }.merge(extra.stringify_keys)

      cursor = item.source_cursor.deep_dup
      cursor[stage] = cursor_end
      @rows_scanned += rows_scanned.to_i
      @facts_inserted += inserted.to_i
      @facts_updated += updated.to_i
      @last_chunk_ms = duration_ms.to_i

      item.update!(
        source_cursor: cursor,
        rows_scanned: item.rows_scanned.to_i + rows_scanned.to_i,
        facts_written: item.facts_written.to_i + inserted.to_i + updated.to_i,
        metrics: metrics.merge("chunks" => chunks)
      )
    end

    def next_item(run)
      run
        .items
        .where.not(status: %w[certified failed stale])
        .order(:id)
        .first
    end

    def source_stage_items(run, stage)
      run
        .items
        .where(stage: stage)
        .where.not(status: %w[certified failed stale])
        .order(:id)
        .to_a
    end

    def all_items_certified?(run)
      run.items.where.not(status: "certified").none?
    end

    def finish_run!(run)
      run.addresses.delete_all
      run.update!(
        status: "completed",
        completed_at: Time.current,
        paused_at: nil,
        last_error: nil
      )

      Result.new(
        ok: true,
        reason: :completed,
        run: run,
        chunks_processed: @chunks_processed,
        elapsed_ms: elapsed_ms,
        last_chunk_ms: @last_chunk_ms,
        facts_inserted: @facts_inserted,
        facts_updated: @facts_updated,
        rows_scanned: @rows_scanned,
        pause_reason: nil
      )
    end

    def pause_run!(run, reason)
      run.items.where(status: "building").update_all(
        status: "paused",
        updated_at: Time.current
      )
      run.update!(
        status: "paused",
        paused_at: Time.current,
        last_error: reason.to_s
      )

      Result.new(
        ok: true,
        reason: reason,
        run: run,
        chunks_processed: @chunks_processed,
        elapsed_ms: elapsed_ms,
        last_chunk_ms: @last_chunk_ms,
        facts_inserted: @facts_inserted,
        facts_updated: @facts_updated,
        rows_scanned: @rows_scanned,
        pause_reason: reason
      )
    end

    def stop_after_chunk!(run)
      Result.new(
        ok: true,
        reason: :stopped_after_chunk,
        run: run,
        chunks_processed: @chunks_processed,
        elapsed_ms: elapsed_ms,
        last_chunk_ms: @last_chunk_ms,
        facts_inserted: @facts_inserted,
        facts_updated: @facts_updated,
        rows_scanned: @rows_scanned,
        pause_reason: :stopped_after_chunk
      )
    end

    def max_chunks_reached?
      max_chunks.present? && @chunks_processed >= max_chunks
    end

    def pause_after_chunks_reached?
      pause_after_chunks.present? && @chunks_processed >= pause_after_chunks
    end

    def stop_after_chunks_reached?
      stop_after_chunks.present? && @chunks_processed >= stop_after_chunks
    end

    def budget_prevents_next_chunk?
      return false unless budget_seconds.present?

      estimate_seconds =
        if @last_chunk_ms.present?
          @last_chunk_ms.to_f / 1000.0
        else
          min_chunk_margin_seconds
        end

      elapsed_seconds + estimate_seconds >= budget_seconds
    end

    def preemption_reason(run)
      return nil unless preemption_check

      preemption_check.call(run)
    end

    def prepare_run!(run)
      checkpoint =
        ClusterProcessedBlock
          .where(status: "processed")
          .order(height: :desc)
          .first

      unless checkpoint&.height.to_i == target_checkpoint_height &&
             checkpoint.block_hash.to_s == target_checkpoint_hash
        raise StaleRunError, "cluster checkpoint changed"
      end

      verify_disk_limits!

      cluster_ids =
        run.items.order(:id).pluck(:cluster_id).uniq

      clusters =
        Cluster
          .lock
          .where(id: cluster_ids)
          .order(:id)
          .index_by(&:id)

      missing = cluster_ids - clusters.keys
      raise StaleRunError, "missing clusters #{missing.join(',')}" if missing.any?

      ApplicationRecord.transaction do
        run.lock!
        run.reload

        raise StaleRunError, "backfill run became stale" if run.stale?

        run.items.order(:id).each do |item|
          cluster = clusters.fetch(item.cluster_id)
          revision = cluster.composition_version.to_i

          if revision < 1
            raise StaleRunError,
                  "invalid composition revision #{cluster.id}"
          end

          if item.composition_version.to_i != revision
            raise StaleRunError,
                  "composition revision changed for cluster #{cluster.id}"
          end

          generation = item.projection_generation

          if generation.present?
            raise StaleRunError,
                  "projection generation became stale for cluster #{cluster.id}" if
              generation.stale? || generation.failed?
          end

          generation ||=
            existing_generation_for(item, cluster)

          generation ||=
            ensure_no_foreign_building_generation!(cluster, item)

          generation ||=
            ClusterTransactionProjectionGeneration.create!(
              cluster_id: cluster.id,
              composition_version: revision,
              base_checkpoint_height: target_checkpoint_height,
              base_checkpoint_hash: target_checkpoint_hash,
              checkpoint_height: target_checkpoint_height,
              checkpoint_hash: target_checkpoint_hash,
              source: source,
              status: "building",
              started_at: Time.current
            )

          item.update!(
            projection_generation: generation,
            status: "pending",
            stage: STAGES.first,
            last_error: nil
          )
        end

        insert_backfill_addresses!(run, clusters)
      end
    rescue StaleRunError => error
      mark_stale!(run, error.message)
      raise
    end

    def existing_generation_for(item, cluster)
      generation =
        ClusterTransactionProjectionGeneration
          .where(
            cluster_id: cluster.id,
            composition_version: item.composition_version.to_i,
            base_checkpoint_height: target_checkpoint_height,
            base_checkpoint_hash: target_checkpoint_hash,
            checkpoint_height: target_checkpoint_height,
            checkpoint_hash: target_checkpoint_hash,
            source: source
          )
          .order(:id)
          .first

      return nil if generation.blank?
      return generation unless generation.stale? || generation.failed?

      raise StaleRunError,
            "projection generation became stale for cluster #{cluster.id}"
    end

    def ensure_no_foreign_building_generation!(cluster, item)
      conflict =
        ClusterTransactionProjectionGeneration
          .where(
            cluster_id: cluster.id,
            status: "building"
          )
          .order(:id)
          .first

      return nil unless conflict

      return conflict if
        conflict.composition_version.to_i == item.composition_version.to_i &&
          conflict.base_checkpoint_height.to_i ==
            target_checkpoint_height &&
          conflict.base_checkpoint_hash.to_s == target_checkpoint_hash &&
          conflict.checkpoint_height.to_i == target_checkpoint_height &&
          conflict.checkpoint_hash.to_s == target_checkpoint_hash &&
          conflict.source.to_s == source

      raise StaleRunError,
            "cluster #{cluster.id} already has a building generation"
    end

    def mark_stale!(run, reason)
      run.update!(
        status: "stale",
        stale_at: Time.current,
        stale_reason: reason,
        last_error: reason
      )

      run.items.update_all(
        status: "stale",
        last_error: reason,
        updated_at: Time.current
      )
    end

    def insert_backfill_addresses!(run, clusters)
      values =
        Address
          .where(cluster_id: clusters.keys)
          .pluck(:id, :cluster_id, :address)
          .map do |address_id, cluster_id, address|
            revision =
              clusters.fetch(cluster_id).composition_version

            {
              run_id: run.id,
              cluster_id: cluster_id,
              address_id: address_id,
              address: address,
              composition_version: revision,
              created_at: Time.current,
              updated_at: Time.current
            }
          end

      return if values.empty?

      ClusterTransactionProjectionBackfillAddress.insert_all(
        values,
        unique_by:
          :idx_ctp_backfill_addresses_run_cluster_address
      )
    end

    def verify_no_competing_run!
      active =
        ClusterTransactionProjectionBackfillRun
          .where(status: %w[pending running paused stale])
          .exists?

      raise "cluster transaction backfill already active" if active
    end

    def verify_no_building_generations!
      active =
        ClusterTransactionProjectionGeneration
          .where(cluster_id: cluster_ids, status: "building")
          .exists?

      raise "cluster transaction generation already building" if active
    end

    def verify_no_strict_io_owner!
      owner = StrictPipeline::StrictIoLease.current
      raise "strict IO lease already held by #{owner.owner}" if owner
    end

    def verify_target_checkpoint!
      checkpoint =
        ClusterProcessedBlock
          .where(status: "processed")
          .order(height: :desc)
          .first

      unless checkpoint&.height.to_i == target_checkpoint_height &&
             checkpoint.block_hash.to_s == target_checkpoint_hash
        raise "cluster checkpoint changed"
      end
    end

    def verify_item_composition!(item)
      cluster = Cluster.find(item.cluster_id)
      return if cluster.composition_version.to_i == item.composition_version.to_i

      item.projection_generation.update!(
        status: "stale",
        stale_reason: "composition_revision_changed",
        stale_at: Time.current
      )
      item.update!(
        status: "stale",
        last_error: "composition_revision_changed"
      )
      raise "composition revision changed for cluster #{item.cluster_id}"
    end

    def verify_disk_limits!
      free = disk_free_bytes
      raise "disk free below limit #{free}" if free < min_free_bytes

      size = projection_bytes
      raise "pilot projection size above limit #{size}" if size > max_pilot_bytes
    end

    def disk_free_bytes
      line =
        IO
          .popen(["df", "-Pk", Rails.root.to_s], &:read)
          .lines
          .last

      line.split[3].to_i * 1024
    end

    def projection_bytes
      tables =
        %w[
          cluster_transaction_projection_generations
          cluster_transaction_facts
          cluster_transaction_projection_blocks
          cluster_transaction_projection_backfill_runs
          cluster_transaction_projection_backfill_items
          cluster_transaction_projection_backfill_addresses
        ]

      sql = <<~SQL.squish
        SELECT COALESCE(SUM(pg_total_relation_size(quote_ident(table_name)::regclass)), 0)
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name IN (#{tables.map { |table| ActiveRecord::Base.connection.quote(table) }.join(", ")})
      SQL

      ActiveRecord::Base.connection.select_value(sql).to_i
    end

    def acquire_lease!
      if external_lease?
        @lease = external_lease
        return
      end

      @lease =
        StrictPipeline::StrictIoLease.acquire(
          OWNER,
          ttl_seconds: StrictPipeline::StrictIoLease.ttl_seconds_default
        )

      raise "strict IO lease denied" unless @lease
    end

    def renew_lease!
      renewed =
        StrictPipeline::StrictIoLease.renew(
          owner: @lease.owner,
          token: @lease.token,
          ttl_seconds: StrictPipeline::StrictIoLease.ttl_seconds_default
        )

      raise "strict IO lease renewal denied" unless renewed
    end

    def release_lease
      return unless @lease

      StrictPipeline::StrictIoLease.release(
        owner: @lease.owner,
        token: @lease.token
      )
    ensure
      @lease = nil
    end

    def external_lease?
      external_lease.present?
    end

    def elapsed_seconds
      return 0 unless @started_at

      Process.clock_gettime(Process::CLOCK_MONOTONIC) -
        @started_at
    end

    def elapsed_ms
      (elapsed_seconds * 1000).round
    end

    def sanitize(sql, binds)
      ActiveRecord::Base.sanitize_sql_array([sql, binds])
    end

    Result = Struct.new(
      :ok,
      :reason,
      :run,
      :chunks_processed,
      :elapsed_ms,
      :last_chunk_ms,
      :facts_inserted,
      :facts_updated,
      :rows_scanned,
      :pause_reason,
      keyword_init: true
    )
  end
end
