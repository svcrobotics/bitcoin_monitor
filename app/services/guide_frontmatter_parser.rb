# frozen_string_literal: true

class GuideFrontmatterParser
  def self.call(raw)
    text = raw.to_s

    # frontmatter YAML-like minimaliste entre --- et ---
    return {} unless text.start_with?("---")

    parts = text.split(/^---\s*$\n?/).reject(&:blank?)
    # parts[0] devrait être le bloc meta
    meta_block = parts[0].to_s

    meta = {}
    meta_block.each_line do |line|
      k, v = line.split(":", 2)
      next if k.blank? || v.blank?
      meta[k.strip.to_sym] = v.strip.gsub(/\A"|"\z/, "")
    end

    meta
  rescue
    {}
  end
end
