# app/models/journal_entry.rb
class JournalEntry < ApplicationRecord
  KINDS = %w[observation hypothese decision resultat].freeze
  MOODS = %w[green amber red neutral].freeze

  validates :occurred_at, presence: true
  validates :kind, inclusion: { in: KINDS }, allow_blank: true
  validates :mood, inclusion: { in: MOODS }, allow_blank: true

  scope :recent, -> { order(occurred_at: :desc) }

  def tags_list
    tags.to_s.split(",").map(&:strip).reject(&:blank?)
  end
end
