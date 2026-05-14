class SystemSnapshot < ApplicationRecord
  validates :name, presence: true
  validates :payload, presence: true
  validates :captured_at, presence: true

  scope :recent_first, -> { order(captured_at: :desc) }

  def self.latest(name)
    where(name: name.to_s).recent_first.first
  end

  def self.capture!(name, payload)
    create!(
      name: name.to_s,
      payload: payload,
      captured_at: Time.current
    )
  end

  def self.prune!(keep: 20)
    distinct.pluck(:name).each do |snapshot_name|
      ids_to_keep =
        where(name: snapshot_name)
          .order(captured_at: :desc)
          .limit(keep)
          .pluck(:id)

      where(name: snapshot_name)
        .where.not(id: ids_to_keep)
        .delete_all
    end
  end
end