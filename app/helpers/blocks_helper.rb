# app/helpers/blocks_helper.rb
module BlocksHelper
  def short_hash(hash)
    return "" if hash.blank?
    "#{hash[0]}…#{hash[-8..-1]}"
  end
end