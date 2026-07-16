# frozen_string_literal: true

require "test_helper"

class AboutBrandingTest < ActiveSupport::TestCase
  test "uses the Tansa brand across every About locale" do
    translations = %i[en es fr zh-CN].to_h do |locale|
      [locale, I18n.t(:about, locale: locale)]
    end

    expected_keys = translations.fetch(:fr).deep_stringify_keys.keys.sort

    translations.each do |locale, about|
      text = about.deep_stringify_keys.to_json

      assert_includes text, "Tansa", locale
      assert_not_includes text, "Bitcoin Monitor", locale
      assert_equal expected_keys, about.deep_stringify_keys.keys.sort, locale
    end
  end
end
