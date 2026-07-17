# frozen_string_literal: true

require "test_helper"

module Layer1
  class PacePresenterTest < ActiveSupport::TestCase
    test "renders catching up rate as rattrapage" do
      presenter =
        Layer1::PacePresenter.new(
          snapshot(trend: "catching_up", backlog_change: -0.67)
        )

      assert_equal "Rattrapage", presenter.backlog_card_title
      assert_equal "0,67 bloc / heure", presenter.backlog_rate_label
      assert_equal "Le retard diminue actuellement.", presenter.backlog_subtext
    end

    test "renders falling behind rate as accumulation" do
      presenter =
        Layer1::PacePresenter.new(
          snapshot(trend: "falling_behind", backlog_change: 2.4)
        )

      assert_equal "Accumulation", presenter.backlog_card_title
      assert_equal "2,40 blocs / heure", presenter.backlog_rate_label
      assert_equal "Le retard augmente actuellement.", presenter.backlog_subtext
    end

    test "renders stable cadence" do
      presenter =
        Layer1::PacePresenter.new(
          snapshot(trend: "stable", backlog_change: 0.08)
        )

      assert_equal "Écart de cadence", presenter.backlog_card_title
      assert_equal "< 0,10 bloc / heure", presenter.backlog_rate_label
      assert_equal(
        "Le retard devrait rester relativement stable.",
        presenter.backlog_subtext
      )
    end

    test "humanizes catchup minutes" do
      presenter =
        Layer1::PacePresenter.new(snapshot)

      assert_equal "42 min", presenter.human_hours(0.7)
    end

    test "humanizes catchup hours" do
      presenter =
        Layer1::PacePresenter.new(snapshot)

      assert_equal "3 h 30 min", presenter.human_hours(3.5)
    end

    test "humanizes catchup days and hours" do
      presenter =
        Layer1::PacePresenter.new(snapshot)

      assert_equal "3 jours 12 h", presenter.human_hours(84)
    end

    test "formats rounded durations without sixty seconds" do
      presenter =
        Layer1::PacePresenter.new(snapshot)

      assert_equal "2 min 00 s", presenter.format_duration(119.5)
      assert_equal "2 min 00 s", presenter.format_duration(119.9)
      assert_equal "2 min 00 s", presenter.format_duration(120)
      assert_equal "3 min 00 s", presenter.format_duration(179.9)
    end

    test "hides precise catchup estimate when net rate is too weak" do
      presenter =
        Layer1::PacePresenter.new(
          snapshot(
            trend: "catching_up",
            backlog_change: -0.2,
            estimated_catchup_hours: 300
          )
        )

      assert_equal(
        "Cadences presque équilibrées. Estimation de rattrapage trop instable.",
        presenter.catchup_sentence
      )
    end

    test "renders catchup estimate when rate is reliable" do
      presenter =
        Layer1::PacePresenter.new(
          snapshot(
            trend: "catching_up",
            backlog_change: -0.67,
            estimated_catchup_hours: 84
          )
        )

      assert_includes presenter.catchup_sentence, "environ 3 jours 12 h"
      assert_includes(
        presenter.catchup_sentence,
        "sensible à la cadence des prochains blocs"
      )
    end

    test "labels negative delta as catchup gain" do
      presenter =
        Layer1::PacePresenter.new(snapshot)

      assert_equal(
        ["Gain de rattrapage", "18 min 11 s"],
        presenter.delta_label(-1091)
      )
    end

    test "labels positive delta as added lag" do
      presenter =
        Layer1::PacePresenter.new(snapshot)

      assert_equal(
        ["Retard ajouté", "5 min 39 s"],
        presenter.delta_label(339)
      )
    end

    test "labels near zero delta as balanced" do
      presenter =
        Layer1::PacePresenter.new(snapshot)

      assert_equal(
        ["Cadence équilibrée", nil],
        presenter.delta_label(8)
      )
    end

    private

    def snapshot(
      trend: "catching_up",
      backlog_change: -0.67,
      estimated_catchup_hours: nil
    )
      {
        comparison: {
          trend: trend,
          backlog_change_per_hour: backlog_change,
          estimated_catchup_hours: estimated_catchup_hours,
          pace_ratio: 0.94
        }
      }
    end
  end
end
