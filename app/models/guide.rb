class Guide < ApplicationRecord
  # Scopes
  scope :published, -> { where(status: "published") }
  scope :featured,  -> { where(featured: true) }
  scope :ordered,   -> { order(:position, :title) }

  # URLs basées sur le slug
  def to_param
    slug
  end

  # Validations
  validates :title, presence: true
  validates :slug,
            presence: true,
            uniqueness: true,
            format: {
              with: /\A[a-z0-9]+(-[a-z0-9]+)*\z/,
              message: "doit contenir uniquement des minuscules, chiffres et tirets"
            }

  # Callbacks
  before_validation :generate_slug_from_title
  before_validation :normalize_slug

  private

  # Génère un slug depuis le titre si vide
  def generate_slug_from_title
    return unless slug.blank? && title.present?

    self.slug = title.parameterize
  end

  # Nettoyage final du slug (même si édité à la main)
  def normalize_slug
    return if slug.blank?

    self.slug = slug
      .downcase
      .unicode_normalize(:nfkd)
      .gsub(/\p{Mn}/, "")          # enlève accents
      .gsub(/[^a-z0-9\s-]/, "")    # enlève ponctuation
      .strip
      .gsub(/\s+/, "-")
      .gsub(/-+/, "-")
  end
end
