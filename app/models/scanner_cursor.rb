# app/models/scanner_cursor.rb
class ScannerCursor < ApplicationRecord
  validates :name, presence: true, uniqueness: true
end