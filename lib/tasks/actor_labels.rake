# frozen_string_literal: true

namespace :actor_labels do
  desc "Run the resumable read-only ActorLabels full audit"
  task full_audit: :environment do
    integer_env =
      lambda do |name, default, minimum, maximum|
        value =
          Integer(
            ENV.fetch(
              name,
              default.to_s
            )
          )

        [
          [value, minimum].max,
          maximum
        ].min
      rescue ArgumentError, TypeError
        default
      end

    limit =
      integer_env.call(
        "ACTOR_LABEL_FULL_AUDIT_LIMIT",
        ActorLabels::FullAudit::DEFAULT_LIMIT,
        1,
        ActorLabels::StrictBatch::MAX_LIMIT
      )

    pause_seconds =
      integer_env.call(
        "ACTOR_LABEL_FULL_AUDIT_PAUSE_SECONDS",
        10,
        0,
        300
      )

    locked_wait_seconds =
      integer_env.call(
        "ACTOR_LABEL_FULL_AUDIT_LOCK_WAIT_SECONDS",
        5,
        1,
        300
      )

    maximum_locked_wait_seconds =
      integer_env.call(
        "ACTOR_LABEL_FULL_AUDIT_MAX_LOCK_WAIT_SECONDS",
        1_800,
        locked_wait_seconds,
        86_400
      )

    locked_waited =
      0

    puts(
      "[actor_labels:full_audit] " \
      "start limit=#{limit} " \
      "pause_seconds=#{pause_seconds} " \
      "read_only=true"
    )

    loop do
      result =
        ActorLabels::FullAudit.call(
          limit: limit
        )

      if result[:skipped] &&
         result[:reason] == "locked"
        locked_waited +=
          locked_wait_seconds

        if locked_waited >
           maximum_locked_wait_seconds
          abort(
            "[actor_labels:full_audit] " \
            "aborted reason=lock_wait_timeout " \
            "waited_seconds=#{locked_waited}"
          )
        end

        puts(
          "[actor_labels:full_audit] " \
          "waiting_for_incremental " \
          "waited_seconds=#{locked_waited}"
        )

        sleep(
          locked_wait_seconds
        )

        next
      end

      locked_waited =
        0

      unless result[:ok]
        abort(
          "[actor_labels:full_audit] " \
          "failed reason=#{
            result[:reason] || "batch_failed"
          }"
        )
      end

      audit =
        result.fetch(:audit)

      puts(
        JSON.generate(
          status: audit[:status],
          batches: audit[:batches],
          scanned: audit[:scanned],
          expected_labels:
            audit[:expected_labels],
          expected_upserts:
            audit[:expected_upserts],
          expected_deletions:
            audit[:expected_deletions],
          cursor:
            audit[:last_cursor]
        )
      )

      if audit[:status] == "completed"
        puts(
          "\n=== RAPPORT FINAL ACTORLABELS ==="
        )

        puts(
          JSON.pretty_generate(audit)
        )

        break
      end

      sleep(pause_seconds) if
        pause_seconds.positive?
    end
  end

  desc "Show ActorLabels full audit progress and last report"
  task full_audit_status: :environment do
    data =
      Sidekiq.redis do |redis|
        {
          cursor:
            redis.get(
              ActorLabels::FullAudit::CURSOR_KEY
            ),

          state:
            redis.get(
              ActorLabels::FullAudit::STATE_KEY
            ),

          last_report:
            redis.get(
              ActorLabels::FullAudit::LAST_RUN_KEY
            )
        }
      end

    normalized =
      data.transform_values do |value|
        if value.blank?
          nil
        else
          JSON.parse(value)
        end
      rescue JSON::ParserError
        value
      end

    puts(
      JSON.pretty_generate(normalized)
    )
  end
end
