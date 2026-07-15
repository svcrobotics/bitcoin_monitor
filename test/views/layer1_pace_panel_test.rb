# frozen_string_literal: true

require "test_helper"

class Layer1PacePanelTest < ActionView::TestCase
  test "renders certification cadence separately from processing duration" do
    html = render_panel(snapshot)

    assert_includes html, "Certification Layer1"
    assert_match(/Certification Layer1.*?2 min 00 s \/ bloc/m, html)
    assert_includes html, "Durée interne de traitement"
    assert_match(/Durée interne de traitement.*?17 s/m, html)
    assert_match(/Certification médiane.*?2 min 00 s/m, html)
    assert_match(/Certification moyenne.*?2 min 05 s/m, html)
    assert_match(/Cadence de certification Layer1.*?3 min 00 s/m, html)
    assert_match(/Durée interne de traitement.*?13 s/m, html)
  end

  test "does not present processing as certification when cadence is absent" do
    html =
      render_panel(
        snapshot.deep_merge(
          certification: {
            median_10_seconds: nil,
            average_10_seconds: nil,
            blocks_per_hour: nil
          }
        )
      )

    assert_match(/Certification Layer1.*?— \/ bloc/m, html)
    assert_match(/Certification médiane.*?—/m, html)
    assert_match(/Certification moyenne.*?—/m, html)
    assert_match(/Durée interne de traitement.*?17 s/m, html)
    refute_match(/Certification Layer1.*?17 s \/ bloc/m, html)
  end

  test "is a presentation-only partial" do
    source =
      Rails.root
        .join("app/views/questions/answers/_layer1_pace_panel.html.erb")
        .read

    forbidden = %w[
      OverviewSnapshot
      BitcoinRpc
      Redis
      Sidekiq
      BlockBufferModel
    ]

    forbidden.each do |constant|
      refute_includes source, constant
    end
  end

  private

  def render_panel(pace_snapshot)
    html = nil

    assert_no_queries_match(/\S/) do
      html =
        render(
          partial: "questions/answers/layer1_pace_panel",
          locals: { snapshot: pace_snapshot }
        )
    end

    html
  end

  def snapshot
    {
      network: {
        median_interval_seconds: 600
      },
      ingestion: {
        median_interval_seconds: 30
      },
      certification: {
        median_10_seconds: 120,
        average_10_seconds: 125,
        blocks_per_hour: 30
      },
      processing: {
        median_10_seconds: 17,
        average_10_seconds: 19,
        last_height: 956_349
      },
      components: {
        rpc_average_seconds: 1,
        parse_average_seconds: 2,
        db_average_seconds: 3,
        flush_average_seconds: 4,
        dominant_stage: "flush"
      },
      comparison: {
        trend: "stable",
        pace_ratio: 0.2,
        backlog_change_per_hour: 0
      },
      recent_blocks: [
        {
          height: 956_349,
          network_interval_seconds: 600,
          certification_interval_seconds: 180,
          processing_duration_seconds: 13,
          delta_seconds: -420
        }
      ]
    }
  end
end
