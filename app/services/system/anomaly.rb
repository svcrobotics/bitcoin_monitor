# frozen_string_literal: true

module System
  Anomaly =
    Struct.new(
      :code,
      :module_name,
      :severity,
      :title,
      :facts,
      :fingerprint,
      :confirmation_observations,
      keyword_init: true
    ) do
      def to_h
        {
          code: code.to_s,
          module: module_name.to_s,
          severity: severity.to_s,
          title: title.to_s,
          facts: facts.to_h,
          fingerprint: fingerprint.to_s,
          confirmation_observations:
            confirmation_observations.to_i.positive? ?
              confirmation_observations.to_i :
              1
        }
      end
    end
end
