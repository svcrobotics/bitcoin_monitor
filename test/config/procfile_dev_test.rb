# frozen_string_literal: true

require "test_helper"
require "yaml"

class ProcfileDevTest < ActiveSupport::TestCase
  STRICT_QUEUES = %w[
    layer1_strict
    cluster_strict
    actor_profile_strict
    actor_behavior_strict
    actor_labels_strict
  ].freeze

  HEAVY_QUEUES = %w[
    layer1_audit
    tx_outputs_async
    tx_output_projection
    cluster_coverage
  ].freeze

  IMPORTANT_JOBS = {
    "Layer1::StrictTipSyncJob" => "layer1_strict",
    "Clusters::StrictTipSyncJob" => "cluster_strict",
    "ActorProfiles::StrictBatchJob" => "actor_profile_strict",
    "ActorBehaviors::StrictBatchJob" => "actor_behavior_strict",
    "ActorLabels::StrictBatchJob" => "actor_labels_strict",
    "Layer1::Audit::BlockJob" => "layer1_audit",
    "Layer1::TxOutputsSpentSyncJob" => "tx_outputs_async",
    "Layer1::TxOutputProjectionJob" => "tx_output_projection",
    "Clusters::Coverage::MaintenanceJob" => "cluster_coverage",
    "Clusters::Coverage::IncrementalJob" => "cluster_coverage",
    "Layer1::StrictTipSyncKickJob" => "scheduler",
    "Layer1::TxOutputsSpentSyncKickJob" => "scheduler",
    "Layer1::TxOutputProjectionKickJob" => "scheduler"
  }.freeze

  test "each strict and heavy queue has the expected dedicated worker" do
    assert_equal ["sidekiq_layer1_strict"], workers_for("layer1_strict")
    assert_equal ["sidekiq_cluster_strict"], workers_for("cluster_strict")
    assert_equal ["sidekiq_actor_profile_strict"], workers_for("actor_profile_strict")
    assert_equal ["sidekiq_actor_behavior_strict"], workers_for("actor_behavior_strict")
    assert_equal ["sidekiq_actor_labels_strict"], workers_for("actor_labels_strict")
    assert_equal ["sidekiq_layer1_audit"], workers_for("layer1_audit")
    assert_equal ["sidekiq_tx_outputs_async"], workers_for("tx_outputs_async")
    assert_equal ["sidekiq_tx_output_projection"], workers_for("tx_output_projection")
    assert_equal ["sidekiq_cluster_coverage"], workers_for("cluster_coverage")
  end

  test "actor behavior automation is enabled only on scheduler" do
    assert_includes(
      procfile.fetch("scheduler").fetch(:command),
      "ACTOR_BEHAVIOR_AUTO_ENABLED=true"
    )

    refute_includes(
      procfile.fetch("sidekiq_actor_behavior_strict").fetch(:command),
      "ACTOR_BEHAVIOR_AUTO_ENABLED=true"
    )
  end

  test "actor labels has a dedicated write-enabled strict worker" do
    command =
      procfile.fetch("sidekiq_actor_labels_strict").fetch(:command)

    assert_equal ["sidekiq_actor_labels_strict"], workers_for("actor_labels_strict")
    assert_equal 1, procfile.fetch("sidekiq_actor_labels_strict").fetch(:concurrency)
    assert_includes command, "ACTOR_LABEL_WRITE_ENABLED=true"
    assert_includes command, "LAYER1_STRICT_ONLY=1"
    refute_includes command, "actor_labels "
  end

  test "scheduler queue has primary and fallback workers only" do
    assert_equal ["scheduler", "scheduler_fallback"], workers_for("scheduler")
    assert_equal ["scheduler"], procfile.fetch("scheduler").fetch(:queues)
    assert_equal ["scheduler"], procfile.fetch("scheduler_fallback").fetch(:queues)
    assert_includes(
      procfile.fetch("scheduler_fallback").fetch(:command),
      "LAYER1_STRICT_SCHEDULER=1"
    )
  end

  test "strict and heavy workers do not share queues" do
    strict_workers.each do |name, command|
      assert_empty command.fetch(:queues) & HEAVY_QUEUES, name
    end

    heavy_workers.each do |name, command|
      assert_empty command.fetch(:queues) & STRICT_QUEUES, name
    end
  end

  test "no strict queue is consumed by multiple processes" do
    STRICT_QUEUES.each do |queue|
      assert_equal 1, workers_for(queue).size, queue
    end
  end

  test "layer1 strict worker declares required strict environment" do
    command = procfile.fetch("sidekiq_layer1_strict").fetch(:command)

    assert_includes command, "SPENT_OUTPUT_FLUSHER_V2=1"
    assert_includes command, "TX_OUTPUTS_SPENT_ASYNC=1"
    assert_includes command, "SPENT_OUTPUT_FLUSH_BATCH_SIZE=20000"
    assert_includes command, "TX_OUTPUTS_SPENT_ASYNC_BATCH_SIZE=500"
  end

  test "strict io lease ttl is explicit on scheduler layer1 and cluster workers" do
    %w[
      scheduler
      sidekiq_layer1_strict
      sidekiq_cluster_strict
    ].each do |process|
      assert_includes(
        procfile.fetch(process).fetch(:command),
        "STRICT_IO_LEASE_TTL_SECONDS=900",
        process
      )
    end
  end

  test "important job queues have workers" do
    IMPORTANT_JOBS.each do |class_name, expected_queue|
      job_class = class_name.constantize

      assert_equal expected_queue, queue_for(job_class), class_name
      assert workers_for(expected_queue).present?, expected_queue
    end
  end

  test "procfile declares explicit concurrency and heavy nice values" do
    sidekiq_processes.each do |name, command|
      assert command.fetch(:concurrency).positive?, name
    end

    assert_equal 1, procfile.fetch("scheduler").fetch(:concurrency)
    assert_equal 1, procfile.fetch("scheduler_fallback").fetch(:concurrency)
    assert_equal 2, procfile.fetch("sidekiq_layer1_strict").fetch(:concurrency)

    HEAVY_QUEUES.each do |queue|
      workers_for(queue).each do |name|
        assert_operator procfile.fetch(name).fetch(:nice), :>, 0, name
        assert_equal 1, procfile.fetch(name).fetch(:concurrency), name
      end
    end
  end

  test "sidekiq default config does not define a generic strict or heavy worker" do
    config =
      YAML.safe_load(
        procfile_safe_read("config/sidekiq.yml"),
        permitted_classes: [Symbol]
      )
    queues = Array(config[:queues] || config["queues"]).map(&:first)

    assert_equal ["scheduler"], queues
    assert_equal 1, config[:concurrency] || config["concurrency"]
  end

  test "strict scheduler cron classes exist and run on scheduler queue" do
    schedule = procfile_safe_read("config/initializers/layer1_strict_scheduler.rb")

    expected = {
      "Layer1::StrictTipSyncKickJob" => "scheduler",
      "Layer1::TxOutputsSpentSyncKickJob" => "scheduler",
      "Layer1::TxOutputProjectionKickJob" => "scheduler"
    }

    expected.each do |class_name, queue|
      assert_includes schedule, %("class" => "#{class_name}")
      assert_includes schedule, %("queue" => "#{queue}")
      assert_nothing_raised { class_name.constantize }
    end
  end

  test "legacy cron is opt in and scheduled class names are loadable" do
    initializer = procfile_safe_read("config/initializers/sidekiq_cron.rb")

    assert_includes initializer, "SIDEKIQ_LEGACY_CRON"

    scheduled_class_names(initializer).each do |class_name|
      assert_nothing_raised { class_name.constantize }
    end
  end

  test "removed or legacy orchestrators are not planned by scheduler initializers" do
    scheduled =
      scheduled_class_names(
        procfile_safe_read("config/initializers/layer1_strict_scheduler.rb")
      )

    refute_includes scheduled, "Layer1::OrchestratorJob"
    refute_includes scheduled, "Clusters::ClusterInputOrchestratorJob"
  end

  test "bin dev uses procfile dev and guards concurrent generations" do
    script =
      procfile_safe_read("bin/dev")

    assert_includes script, "cd \"$(dirname \"$0\")/..\""
    assert_includes script, "tansa-dev.lock"
    assert_includes script, "TANSA_DEV_LOCK_HELD"
    assert_includes script, "flock --no-fork --exclusive"
    assert_includes script, "exec foreman start -f Procfile.dev"
  end

  test "systemd unit supervises bin dev with the same lock" do
    unit =
      procfile_safe_read("ops/systemd/tansa-dev.service")

    assert_includes unit, "WorkingDirectory=/home/victor/bitcoin_monitor"
    assert_includes unit, "Restart=always"
    assert_includes unit, "KillMode=control-group"
    assert_includes unit, "tansa-dev.lock"
    assert_includes unit, "TANSA_DEV_LOCK_HELD=1"
    assert_includes unit, "exec ./bin/dev"
  end

  test "operational scripts delegate to tansa dev service" do
    assert_includes procfile_safe_read("bin/tansa-restart"), "systemctl --user restart tansa-dev.service"
    assert_includes procfile_safe_read("bin/tansa-stop"), "systemctl --user stop tansa-dev.service"
    assert_includes procfile_safe_read("bin/tansa-logs"), "journalctl --user -u tansa-dev.service"
    assert_includes procfile_safe_read("bin/tansa-status"), "tansa-dev.service"
  end

  private

  def procfile
    @procfile ||= begin
      lines =
        procfile_safe_read("Procfile.dev")
          .each_line
          .map(&:strip)
          .reject { |line| line.blank? || line.start_with?("#") }

      lines.to_h do |line|
        name, command = line.split(":", 2)
        command = command.to_s.strip

        [
          name,
          {
            command: command,
            queues: command.scan(/\s-q\s+([^\s]+)/).flatten,
            concurrency: command[/\s-c\s+(\d+)/, 1].to_i,
            nice: command[/\bnice\s+-n\s+(-?\d+)/, 1].to_i
          }
        ]
      end
    end
  end

  def procfile_safe_read(path)
    Rails.root.join(path).read
  end

  def sidekiq_processes
    procfile.select do |_name, command|
      command.fetch(:command).include?("sidekiq")
    end
  end

  def strict_workers
    sidekiq_processes.select do |_name, command|
      (command.fetch(:queues) & STRICT_QUEUES).present?
    end
  end

  def heavy_workers
    sidekiq_processes.select do |_name, command|
      (command.fetch(:queues) & HEAVY_QUEUES).present?
    end
  end

  def workers_for(queue)
    sidekiq_processes
      .select { |_name, command| command.fetch(:queues).include?(queue) }
      .keys
      .sort
  end

  def queue_for(job_class)
    if job_class < ActiveJob::Base
      job_class.new.queue_name.to_s
    elsif job_class.respond_to?(:get_sidekiq_options)
      job_class.get_sidekiq_options.fetch("queue").to_s
    else
      job_class.queue_name.to_s
    end
  end

  def scheduled_class_names(source)
    source
      .scan(/"class"\s*=>\s*"([^"]+)"/)
      .flatten
      .uniq
  end
end
