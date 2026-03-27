class Address < ApplicationRecord
  belongs_to :cluster, optional: true

  validates :address, presence: true, uniqueness: true
end