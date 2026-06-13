class EconomicIndicator < ApplicationRecord
  validates :code, :name, :source, :observed_on, :value, presence: true
  validates :code, uniqueness: { scope: :observed_on }
end
