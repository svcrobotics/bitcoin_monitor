# frozen_string_literal: true

require "test_helper"
require "nokogiri"

class Layer1CatchupIndicatorsTest < ActionView::TestCase
  test "renders the explicit catchup snapshot values" do
    html = render_progress(
      status: "catching_up",
      phase: "layer1_catchup",
      current_lag: 7,
      baseline_lag: 10,
      blocks_to_target: 5,
      observed_change_per_hour: -2.5,
      estimated_catchup_hours: 2.0
    )

    assert_includes html, "Rattrapage en cours"
    assert_includes html, "layer1_catchup"
    assert_match(/Lag actuel.*?7/m, html)
    assert_match(/Lag initial.*?10/m, html)
    assert_match(/Blocs vers l’objectif.*?5/m, html)
    assert_includes html, "-2.5 bloc/h"
    assert_includes html, "2.0 h"
    assert_includes html, 'data-layer1-catchup-status="catching_up"'
  end

  test "preserves real zeroes without inventing them for missing metrics" do
    html = render_progress(
      status: "target_reached",
      phase: "layer1_catchup",
      current_lag: 0,
      baseline_lag: nil,
      blocks_to_target: 0,
      observed_change_per_hour: nil,
      estimated_catchup_hours: 0.0
    )

    assert_includes html, "Objectif atteint"
    assert_match(/Lag actuel.*?>0</m, html)
    assert_match(/Lag initial.*?—/m, html)
    assert_match(/Blocs vers l’objectif.*?>0</m, html)
    assert_match(/Variation observée.*?—/m, html)
    assert_includes html, "0.0 h"
  end

  test "renders unavailable explicitly without exposing invalid values" do
    html = render_progress(
      status: "unavailable",
      phase: nil,
      current_lag: '<script>alert("lag")</script>',
      error: "Redis::CannotConnectError secret"
    )

    assert_includes html, "Progression indisponible"
    assert_includes html, "Les mesures de progression ne sont pas disponibles actuellement."
    assert_includes html, "Phase&nbsp;: —"
    refute_includes html, "<script>"
    refute_includes html, "Redis::CannotConnectError"
    refute_includes html, "secret"
    assert_includes html, 'data-layer1-catchup-status="unavailable"'
  end

  test "is presentation-only and integrated once without Redis Sidekiq or JavaScript" do
    html = render_progress(status: "measuring", phase: "layer1_catchup")
    fragment = Nokogiri::HTML.fragment(html)
    partial_source = Rails.root.join(
      "app/views/questions/answers/_layer1_catchup_indicators.html.erb"
    ).read
    parent_source = Rails.root.join(
      "app/views/questions/answers/_layer1.html.erb"
    ).read

    assert_equal 1, fragment.css("section[data-layer1-catchup-status]").size
    refute_match(/Redis|Sidekiq|perform_(?:async|in)|javascript|data-controller/, partial_source)
    assert_equal 1, parent_source.scan(/Layer1::CatchupProgressSnapshot\.call/).size
    assert_equal 1, parent_source.scan(/layer1_catchup_indicators/).size
  end

  private

  def render_progress(progress)
    html = nil
    assert_no_queries_match(/\S/) do
      html = render(
        partial: "questions/answers/layer1_catchup_indicators",
        locals: { progress: progress }
      )
    end
    html
  end
end
