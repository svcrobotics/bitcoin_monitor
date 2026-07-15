# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Layer1
  class RecentBlockCadenceSnapshotTest < ActiveSupport::TestCase
    class FakeRpc
      attr_reader :blockhash_calls, :header_calls

      def initialize(times)
        @times = times
        @blockhash_calls = []
        @header_calls = []
      end

      def getblockhash(height)
        @blockhash_calls << height
        "hash-#{height}"
      end

      def getblockheader(hash)
        @header_calls << hash
        height = hash.to_s.delete_prefix("hash-").to_i

        {
          "height" => height,
          "time" => @times[height],
          "previousblockhash" => "hash-#{height - 1}"
        }
      end
    end

    class RaisingRpc < FakeRpc
      def getblockheader(hash)
        super
        raise IOError, "simulated RPC failure"
      end
    end

    test "detects a network burst and labels recent block states" do
      times = {
        100 => 1_000,
        101 => 1_600,
        102 => 1_660,
        103 => 1_700,
        104 => 1_735,
        105 => 1_780
      }

      rpc = FakeRpc.new(times)

      snapshot = Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: 105,
        processed_height: 102,
        processing_height: 103,
        rpc: rpc,
        cache: nil,
        now: Time.at(1_800),
        certification_average_seconds: 90
      )

      assert snapshot[:available]
      assert_equal 3, snapshot[:lag]
      assert_equal "burst", snapshot[:diagnosis]
      assert_equal "Rafale réseau", snapshot[:diagnosis_label]
      assert_equal 120, snapshot[:backlog_span_seconds]
      assert_equal [105, 104, 103, 102, 101], snapshot[:blocks].pluck(:height)
      assert_equal %w[waiting waiting processing certified certified], snapshot[:blocks].pluck(:state)
      assert_equal [45, 35, 40, 60, 600], snapshot[:blocks].pluck(:interval_seconds)
      assert_includes snapshot[:diagnosis_detail], "3 blocs"
      assert_includes snapshot[:diagnosis_detail], "2 min"
      assert_includes snapshot[:diagnosis_detail], "bloc 103"
      assert_equal [105], rpc.blockhash_calls
      assert_equal %w[hash-105 hash-104 hash-103 hash-102 hash-101 hash-100], rpc.header_calls
    end

    test "flags a three block lag when recent blocks are normally spaced" do
      times = {
        300 => 20_000,
        301 => 20_600,
        302 => 21_200,
        303 => 21_800,
        304 => 22_400,
        305 => 23_000
      }

      snapshot = Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: 305,
        processed_height: 302,
        processing_height: 303,
        rpc: FakeRpc.new(times),
        cache: nil,
        now: Time.at(23_030),
        certification_average_seconds: 70
      )

      assert snapshot[:available]
      assert_equal 3, snapshot[:lag]
      assert_equal "watch", snapshot[:diagnosis]
      assert_equal "Retard à surveiller", snapshot[:diagnosis_label]
      assert_equal 1_800, snapshot[:backlog_span_seconds]
      assert_includes snapshot[:diagnosis_detail], "bloc 303"
    end

    test "reports a waiting block when no processing block is active" do
      times = {
        400 => 30_000,
        401 => 30_600,
        402 => 31_200,
        403 => 31_800,
        404 => 32_400,
        405 => 33_000
      }

      snapshot = Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: 405,
        processed_height: 404,
        processing_height: nil,
        rpc: FakeRpc.new(times),
        cache: nil,
        now: Time.at(33_136),
        certification_average_seconds: 126
      )

      assert_equal 1, snapshot[:lag]
      assert_equal "waiting", snapshot[:diagnosis]
      assert_equal "En attente", snapshot[:diagnosis_label]
      assert_equal 405, snapshot[:waiting_height]
      assert_equal 136, snapshot[:waiting_age_seconds]
      assert_includes snapshot[:diagnosis_detail], "bloc 405"
      assert_includes snapshot[:diagnosis_detail], "attend sa prise en charge"
      refute_includes snapshot[:diagnosis_detail], "traite"
    end

    test "reports an active catch-up when a block is processing" do
      times = {
        500 => 40_000,
        501 => 40_600,
        502 => 41_200,
        503 => 41_800,
        504 => 42_400,
        505 => 43_000
      }

      snapshot = Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: 505,
        processed_height: 504,
        processing_height: 505,
        rpc: FakeRpc.new(times),
        cache: nil,
        now: Time.at(43_030),
        certification_average_seconds: 126
      )

      assert_equal 1, snapshot[:lag]
      assert_equal "catching_up", snapshot[:diagnosis]
      assert_equal "Rattrapage en cours", snapshot[:diagnosis_label]
      assert_includes snapshot[:diagnosis_detail], "bloc 505"
      assert_includes snapshot[:diagnosis_detail], "certifie actuellement"
    end

    test "reports a synchronized chain without inventing a delay" do
      times = {
        200 => 10_000,
        201 => 10_600,
        202 => 11_200,
        203 => 11_800,
        204 => 12_400,
        205 => 13_000
      }

      snapshot = Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: 205,
        processed_height: 205,
        rpc: FakeRpc.new(times),
        cache: nil,
        now: Time.at(13_030),
        certification_average_seconds: 60
      )

      assert snapshot[:available]
      assert_equal 0, snapshot[:lag]
      assert_equal "synced", snapshot[:diagnosis]
      assert_equal 600.0, snapshot[:average_interval_seconds]
      assert_equal 0, snapshot[:backlog_span_seconds]
      assert snapshot[:blocks].all? { |block| block[:state] == "certified" }
      assert_includes snapshot[:diagnosis_detail], "10 min"
    end

    test "fails closed when the Bitcoin Core tip is unavailable" do
      snapshot = Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: nil,
        processed_height: 0,
        rpc: FakeRpc.new({}),
        cache: nil
      )

      refute snapshot[:available]
      assert_equal "unknown", snapshot[:diagnosis]
      assert_empty snapshot[:blocks]
    end


    test "reports a slow cadence without inventing a new business threshold" do
      times = {
        700 => 10_000,
        701 => 11_200,
        702 => 12_400,
        703 => 13_600,
        704 => 14_800,
        705 => 16_000
      }

      snapshot = Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: 705,
        processed_height: 705,
        rpc: FakeRpc.new(times),
        cache: nil,
        now: Time.at(16_030),
        certification_average_seconds: 60
      )

      assert snapshot[:available]
      assert_equal 1_200.0, snapshot[:average_interval_seconds]
      assert_equal "synced", snapshot[:diagnosis]
      assert_includes snapshot[:diagnosis_detail], "20 min"
    end

    test "returns unavailable when fewer than two valid headers exist" do
      rpc = FakeRpc.new(800 => 20_000)

      snapshot = Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: 800,
        processed_height: 799,
        rpc: rpc,
        cache: nil,
        certification_average_seconds: 60
      )

      refute snapshot[:available]
      assert_equal "unknown", snapshot[:diagnosis]
      assert_equal "block_headers_missing", snapshot[:diagnosis_detail]
      assert_equal %w[hash-800 hash-799], rpc.header_calls
    end

    test "normalizes invalid timestamps without producing a negative interval" do
      times = {
        900 => 30_000,
        901 => 30_600,
        902 => 31_200,
        903 => 31_800,
        904 => 31_700,
        905 => 32_400
      }

      snapshot = Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: 905,
        processed_height: 905,
        rpc: FakeRpc.new(times),
        cache: nil,
        now: Time.at(32_430),
        certification_average_seconds: 60
      )

      anomalous = snapshot[:blocks].find { |block| block[:height] == 904 }

      assert snapshot[:available]
      assert_nil anomalous[:interval_seconds]
      assert anomalous[:timestamp_anomaly]
      assert snapshot[:blocks].all? { |block| block[:interval_seconds].nil? || block[:interval_seconds].positive? }
    end

    test "fails closed when the injected RPC raises" do
      snapshot = Realtime::RecentBlockCadenceSnapshot.call(
        tip_height: 1_000,
        processed_height: 999,
        rpc: RaisingRpc.new(1_000 => 40_000),
        cache: nil,
        certification_average_seconds: 60
      )

      refute snapshot[:available]
      assert_equal "unknown", snapshot[:diagnosis]
      assert_includes snapshot[:diagnosis_detail], "IOError"
      assert_includes snapshot[:diagnosis_detail], "simulated RPC failure"
    end

    test "legacy adapter delegates once to the canonical service" do
      expected = { available: true, diagnosis: "sentinel" }
      calls = []
      replacement = lambda do |**kwargs|
        calls << kwargs
        expected
      end
      kwargs = {
        tip_height: 1_100,
        processed_height: 1_099,
        rpc: FakeRpc.new({}),
        cache: nil,
        certification_average_seconds: 60
      }

      result = Realtime::RecentBlockCadenceSnapshot.stub(:call, replacement) do
        RecentBlockCadenceSnapshot.call(**kwargs)
      end

      assert_same expected, result
      assert_equal [kwargs], calls
    end

    test "result is serializable and has no SQL Redis Sidekiq or network side effect" do
      times = {
        1_200 => 50_000,
        1_201 => 50_600,
        1_202 => 51_200,
        1_203 => 51_800,
        1_204 => 52_400,
        1_205 => 53_000
      }
      rpc = FakeRpc.new(times)
      sql = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        sql << payload[:sql].to_s
      end

      snapshot = ActiveSupport::Notifications.subscribed(
        subscriber,
        "sql.active_record"
      ) do
        Realtime::RecentBlockCadenceSnapshot.call(
          tip_height: 1_205,
          processed_height: 1_205,
          rpc: rpc,
          cache: nil,
          now: Time.at(53_030),
          certification_average_seconds: 60
        )
      end

      parsed = JSON.parse(JSON.generate(snapshot))
      source = Rails.root.join(
        "app/services/layer1/realtime/recent_block_cadence_snapshot.rb"
      ).read

      assert_equal true, parsed.fetch("available")
      assert_equal [1_205], rpc.blockhash_calls
      assert_equal 6, rpc.header_calls.size
      assert_empty sql
      refute_match(/\bRedis\b|\bSidekiq\b|perform_(?:async|later|in)/, source)
      refute_match(/Net::HTTP|Faraday|HTTP\.get/, source)
    end
  end
end
