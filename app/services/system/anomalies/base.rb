# frozen_string_literal: true

module System
  module Anomalies
    module Base
      module_function

      def anomaly(
        code:,
        module_name:,
        severity:,
        title:,
        facts:,
        fingerprint:,
        confirmation_observations: 1
      )
        System::Anomaly.new(
          code: code,
          module_name: module_name,
          severity: severity,
          title: title,
          facts: facts,
          fingerprint: fingerprint,
          confirmation_observations: confirmation_observations
        )
      end
    end
  end
end
