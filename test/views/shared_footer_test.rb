# frozen_string_literal: true

require "test_helper"

class SharedFooterTest < ActionView::TestCase
  test "shows the Tansa brand without changing footer navigation" do
    expected_paths = [
      root_path,
      guides_path,
      opsec_path,
      about_path,
      system_path,
      contact_path,
      terms_path,
      privacy_path,
      risk_disclosure_path
    ]

    %i[en es fr zh-CN].each do |locale|
      I18n.with_locale(locale) do
        html = render partial: "shared/footer"
        footer = Nokogiri::HTML.fragment(html).at_css("footer")

        assert footer
        assert_equal 4, footer.css(".grid > div").size
        assert_equal expected_paths, footer.css("a").map { |link| link["href"] }
        assert_equal ["Tansa"], footer.css(".font-semibold").map { |node| node.text.strip }
        assert_not_includes html, "Bitcoin Monitor"
      end
    end
  end
end
