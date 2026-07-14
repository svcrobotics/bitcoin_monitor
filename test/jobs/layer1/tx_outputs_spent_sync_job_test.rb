# frozen_string_literal: true

require "test_helper"

module Layer1
  class TxOutputsSpentSyncJobTest < ActiveSupport::TestCase
    Checkpoint = Struct.new(:height)

    test "checks the gate before claiming and stops when it refuses" do
      gate = { ready: false, reasons: ["layer1_processing"] }

      with_worker(gate: gate) do |job, calls, scheduled, events|
        result = job.perform

        assert_equal true, result[:ok]
        assert_equal "deferred", result[:status]
        assert_equal gate, result[:gate]
        assert_equal [:gate], events
        assert_equal 0, calls[:next_record]
        assert_equal 0, calls[:sync_height]
        assert_equal 0, calls[:work_available]
        assert_empty scheduled
      end
    end

    test "finishes cleanly when the claim disappears after a positive gate" do
      with_worker(gate: { ready: true }, record: nil) do |job, calls, scheduled, events|
        result = job.perform

        assert_equal true, result[:ok]
        assert_equal "idle", result[:status]
        assert_equal [:gate, :next_record], events
        assert_equal 1, calls[:next_record]
        assert_equal 0, calls[:sync_height]
        assert_equal 0, calls[:work_available]
        assert_empty scheduled
      end
    end

    test "processes one claim and schedules once when more work is indicated" do
      checkpoint = Checkpoint.new(400)
      sync_result = {
        ok: true,
        status: "pending",
        height: checkpoint.height,
        rows_updated: 500,
        remaining_rows: 1
      }

      with_worker(
        gate: { ready: true },
        record: checkpoint,
        sync_result: sync_result,
        work_available: true
      ) do |job, calls, scheduled, events|
        result = job.perform

        assert_equal sync_result, result
        assert_equal 1, calls[:next_record]
        assert_equal 1, calls[:sync_height]
        assert_equal [checkpoint], calls[:sync_records]
        assert_equal 1, calls[:work_available]
        assert_equal [1], scheduled
        assert_equal(
          [:gate, :next_record, :sync_height, :work_available, :schedule],
          events
        )
      end
    end

    test "does not schedule when the read only probe finds no more work" do
      checkpoint = Checkpoint.new(401)

      with_worker(
        gate: { ready: true },
        record: checkpoint,
        work_available: false
      ) do |job, calls, scheduled, events|
        result = assert_no_queries_match(/\b(?:INSERT|UPDATE|DELETE)\b/i) do
          job.perform
        end

        assert_equal true, result[:ok]
        assert_equal 1, calls[:next_record]
        assert_equal 1, calls[:sync_height]
        assert_equal 1, calls[:work_available]
        assert_empty scheduled
        assert_equal [:gate, :next_record, :sync_height, :work_available], events
      end
    end

    test "preserves engine errors without probing or claiming again" do
      checkpoint = Checkpoint.new(402)
      engine_error = RuntimeError.new("sync failed")

      with_worker(
        gate: { ready: true },
        record: checkpoint,
        sync_error: engine_error,
        work_available: true
      ) do |job, calls, scheduled, events|
        raised = assert_raises(RuntimeError) { job.perform }

        assert_same engine_error, raised
        assert_equal 1, calls[:next_record]
        assert_equal 1, calls[:sync_height]
        assert_equal 0, calls[:work_available]
        assert_empty scheduled
        assert_equal [:gate, :next_record, :sync_height], events
      end
    end

    test "yields after one batch when the post batch guard denies" do
      checkpoint = Checkpoint.new(403)
      denied = {
        allowed: false,
        reason: :layer1_realtime_priority,
        failed_constraints: [:layer1_not_processing]
      }

      with_worker(
        gate: { ready: true },
        record: checkpoint,
        decisions: [{ allowed: true }, denied],
        work_available: true
      ) do |job, calls, scheduled, events|
        result = job.perform

        assert_equal true, result[:ok]
        assert_equal "yielded_to_layer1", result[:status]
        assert_equal denied, result[:decision]
        assert_equal 1, calls[:next_record]
        assert_equal 1, calls[:sync_height]
        assert_equal 0, calls[:work_available]
        assert_empty scheduled
        assert_equal [:gate, :next_record, :sync_height], events
      end
    end

    private

    def with_worker(
      gate:,
      record: nil,
      sync_result: { ok: true, status: "synced" },
      sync_error: nil,
      work_available: false,
      decisions: [{ allowed: true }, { allowed: true }]
    )
      job = TxOutputsSpentSyncJob.new
      calls = Hash.new(0)
      calls[:sync_records] = []
      scheduled = []
      events = []
      remaining_decisions = decisions.dup

      with_stubbed(TxOutputsSpentSync::Config, :enabled?, true) do
        with_stubbed(
          job,
          :pipeline_decision,
          -> { remaining_decisions.shift || { allowed: true } }
        ) do
          with_stubbed(job, :with_lock, ->(&block) { block.call }) do
            with_stubbed(
              TxOutputsSpentSync::Gate,
              :call,
              lambda {
                calls[:gate] += 1
                events << :gate
                gate
              }
            ) do
              with_stubbed(
                TxOutputsSpentSync::NextRecord,
                :call,
                lambda {
                  calls[:next_record] += 1
                  events << :next_record
                  record
                }
              ) do
                with_stubbed(
                  TxOutputsSpentSync::SyncHeight,
                  :call,
                  lambda { |sync_record:|
                    calls[:sync_height] += 1
                    calls[:sync_records] << sync_record
                    events << :sync_height
                    raise sync_error if sync_error

                    sync_result
                  }
                ) do
                  with_stubbed(
                    TxOutputsSpentSync::WorkAvailable,
                    :call,
                    lambda {
                      calls[:work_available] += 1
                      events << :work_available
                      work_available
                    }
                  ) do
                    with_stubbed(
                      TxOutputsSpentSyncJob,
                      :perform_in,
                      lambda { |delay|
                        scheduled << delay
                        events << :schedule
                      }
                    ) do
                      yield job, calls, scheduled, events
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    def with_stubbed(object, method_name, value = nil)
      original = object.method(method_name)
      replacement =
        if value.respond_to?(:call)
          value
        else
          ->(*_args, **_kwargs) { value }
        end

      object.define_singleton_method(method_name, &replacement)

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
