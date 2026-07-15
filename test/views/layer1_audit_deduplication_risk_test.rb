# frozen_string_literal: true

require "test_helper"
require "nokogiri"

class Layer1AuditDeduplicationRiskTest < ActionView::TestCase
  test "renders healthy queue latency TTL and ratio" do
    html = render_risk(risk(status: "healthy", latency: 900, ratio: 0.25))

    assert_includes html, "Marge de déduplication saine"
    assert_includes html, "900 s"
    assert_includes html, "3 600 s"
    assert_includes html, "25%"
    assert_includes html, 'data-deduplication-risk-status="healthy"'
  end

  test "renders warning with its visual marker" do
    html = render_risk(risk(status: "warning", latency: 1_800, ratio: 0.5))

    assert_includes html, "Expiration de la déduplication à surveiller"
    assert_includes html, 'data-deduplication-risk-status="warning"'
    assert_includes html, "border-amber-500/30"
    assert_includes html, "50%"
  end

  test "renders critical without reassuring wording" do
    html = render_risk(risk(status: "critical", latency: 3_600, ratio: 1.0))

    assert_includes html, "Risque d’expiration de la déduplication"
    assert_includes html, 'data-deduplication-risk-status="critical"'
    refute_includes html, "Marge de déduplication saine"
  end

  test "renders unavailable and nil metrics as dashes without false zeroes" do
    html =
      render_risk(
        status: "unavailable",
        queue_latency_seconds: nil,
        marker_ttl_seconds: nil,
        queue_latency_to_ttl_ratio: nil
      )

    assert_includes html, "Risque de déduplication indisponible"
    assert_equal 3, html.scan("—").size
    refute_match(/>\s*0(?:[\s,%]|<)/, html)
  end

  test "does not calculate a percentage when the ratio is absent" do
    html = render_risk(risk(status: "warning", latency: 1_800, ratio: nil))

    assert_match(/Ratio latence \/ TTL.*?—/m, html)
    refute_includes html, "50%"
  end

  test "rejects hostile values and exposes no internal data" do
    html =
      render_risk(
        status: '<script>alert("status")</script>',
        queue_latency_seconds: '<img src=x onerror="alert(1)">',
        marker_ttl_seconds: "token-secret",
        queue_latency_to_ttl_ratio: "payload-backtrace-internal-error"
      )

    assert_includes html, "Risque de déduplication indisponible"
    refute_includes html, "<script>"
    refute_includes html, "<img"
    refute_includes html, "token-secret"
    refute_includes html, "payload-backtrace-internal-error"
    assert_equal 3, html.scan("—").size
  end

  test "is valid presentation-only HTML without SQL Redis Sidekiq or Overview access" do
    html = render_risk(risk(status: "healthy", latency: 0, ratio: 0))
    fragment = Nokogiri::HTML.fragment(html)
    source =
      Rails.root
        .join("app/views/layer1_audit/_deduplication_expiry_risk.html.erb")
        .read

    assert_equal 1, fragment.css("section[data-deduplication-risk-status]").size
    refute_match(/OverviewSnapshot|Redis\.|Redis::|Sidekiq::|perform_(?:async|in)/, source)
  end

  private

  def render_risk(value)
    html = nil

    assert_no_queries_match(/\S/) do
      html =
        render(
          partial: "layer1_audit/deduplication_expiry_risk",
          locals: { risk: value }
        )
    end

    html
  end

  def risk(status:, latency:, ratio:)
    {
      status: status,
      queue_latency_seconds: latency,
      marker_ttl_seconds: 3_600,
      queue_latency_to_ttl_ratio: ratio
    }
  end
end
