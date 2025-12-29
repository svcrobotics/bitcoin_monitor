# app/models/guide.rb
class Guide < ApplicationRecord
  scope :published, -> { where(status: "published") }
  scope :featured,  -> { where(featured: true) }
  scope :ordered,   -> { order(:position, :title) }
end
