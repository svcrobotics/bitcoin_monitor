# frozen_string_literal: true

module Clusters
  class HealthSnapshot
    def self.call
      new.call
    end

    def call
      Clusters::StrictHealthSnapshot.call
    end
  end
end
