# frozen_string_literal: true

class ClusterTransactionProjectionBackfillAddress < ApplicationRecord
  belongs_to(
    :run,
    class_name: "ClusterTransactionProjectionBackfillRun",
    inverse_of: :addresses
  )

  validates :cluster_id,
    :address_id,
    :address,
    :composition_version,
    presence: true

  validates :composition_version,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 1
    }
end
