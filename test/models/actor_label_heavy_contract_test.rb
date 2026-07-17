# frozen_string_literal: true

require "test_helper"

class ActorLabelHeavyContractTest <
  ActiveSupport::TestCase

  test "allows exchange infrastructure candidate" do
    assert_includes(
      ActorLabel::LABELS,
      "exchange_infrastructure_candidate"
    )
  end

  test "accepts heavy candidate as label value" do
    label =
      ActorLabel.new(
        label:
          "exchange_infrastructure_candidate",

        source:
          ActorLabels::HeavyRuleSet::SOURCE,

        confidence:
          90
      )

    label.valid?

    assert_empty(
      label.errors[:label]
    )
  end
end
