# frozen_string_literal: true

class CodeChunk < ApplicationRecord
  has_neighbors :embedding

  validates :path, :content, :content_hash, presence: true
end