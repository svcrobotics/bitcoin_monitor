# app/models/rune_event.rb
class RuneEvent < ApplicationRecord
  belongs_to :rune_token, optional: true

  scope :etchings,   -> { where(op: "etch") }
  scope :mints,      -> { where(op: "mint") }
  scope :transfers,  -> { where(op: "transfer") }
  scope :burns,      -> { where(op: "burn") }
end
