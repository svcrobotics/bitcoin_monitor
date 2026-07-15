# frozen_string_literal: true

module AddressSpendStats
  class ProjectionJob < ApplicationJob
    queue_as :actor_profile_strict

    DEFAULT_LIMIT = 2
    MAX_LIMIT = 20

    DEFAULT_MAX_RUNTIME_SECONDS = 15
    MAX_RUNTIME_SECONDS = 60

    def perform(
      options = nil,
      limit: nil,
      max_runtime_seconds: nil
    )
      decision = System::PipelineController.decision(:address_spend_projection)
      unless decision.is_a?(Hash) && [true, false].include?(decision[:allowed])
        raise "AddressSpend PipelineController returned an invalid decision"
      end
      return { ok: true, status: "skipped", reason: "pipeline_controller_refused" } unless decision[:allowed]

      normalized =
        normalize_options(options)

      limit_value =
        integer_option(
          normalized[:limit] || limit,
          default:
            Integer(
              ENV.fetch(
                "ADDRESS_SPEND_PROJECTION_JOB_LIMIT",
                DEFAULT_LIMIT.to_s
              )
            ),
          minimum: 1,
          maximum: MAX_LIMIT
        )

      runtime_value =
        integer_option(
          normalized[:max_runtime_seconds] ||
            max_runtime_seconds,
          default:
            Integer(
              ENV.fetch(
                "ADDRESS_SPEND_PROJECTION_JOB_MAX_RUNTIME_SECONDS",
                DEFAULT_MAX_RUNTIME_SECONDS.to_s
              )
            ),
          minimum: 1,
          maximum: MAX_RUNTIME_SECONDS
        )

      result =
        AddressSpendStats::Runner.call(
          limit: limit_value,
          max_runtime_seconds:
            runtime_value,
          lock: true
        )

      if result[:stopped_reason].to_s ==
         "already_running"
        return result.merge(
          status: "skipped",
          reason: "already_running",
          automation:
            automation_payload(
              limit: limit_value,
              max_runtime_seconds:
                runtime_value
            )
        )
      end

      unless result[:ok] == true
        raise(
          "AddressSpend projection failed "           "height=#{result[:failed_height]} "           "error=#{result[:error_class]}: "           "#{result[:error_message]}"
        )
      end

      Rails.logger.info(
        "[address_spend_projection_job] "         "done "         "projected_blocks="         "#{result[:projected_blocks]} "         "first_height="         "#{result[:first_height]} "         "last_height="         "#{result[:last_height]} "         "stopped_reason="         "#{result[:stopped_reason]}"
      )

      result.merge(
        status: "completed",
        automation:
          automation_payload(
            limit: limit_value,
            max_runtime_seconds:
              runtime_value
          )
      )
    end

    private

    def automation_payload(
      limit:,
      max_runtime_seconds:
    )
      {
        queue:
          self.class.queue_name,
        limit: limit,
        max_runtime_seconds:
          max_runtime_seconds,
        reschedule: false
      }
    end

    def normalize_options(options)
      return {} unless
        options.is_a?(Hash)

      if options.respond_to?(
        :with_indifferent_access
      )
        options
          .with_indifferent_access
          .to_h
          .symbolize_keys
      else
        options.transform_keys do |key|
          key.to_sym
        end
      end
    end

    def integer_option(
      value,
      default:,
      minimum:,
      maximum:
    )
      integer =
        Integer(
          value || default
        )

      [
        [
          integer,
          minimum
        ].max,
        maximum
      ].min
    rescue ArgumentError, TypeError
      default
    end
  end
end
