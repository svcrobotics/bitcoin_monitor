# frozen_string_literal: true

require "test_helper"

module Questions
  class LiveAnswersControllerTest < ActionDispatch::IntegrationTest
    test "renders actor behaviors live view" do
      get questions_live_answer_path(
        module_name: "actor_behaviors"
      )

      assert_response :success

      assert_select(
        "turbo-frame#live_answer_actor_behaviors"
      )

      assert_select "h2", text: /Comportements observables/
      assert_match(/ActorBehavior/, response.body)
      assert_match(/Entrées/, response.body)
      assert_match(/Calculs/, response.body)
      assert_match(/Sorties/, response.body)
      assert_match(/ActorLabels/, response.body)
      assert_match(/Voir les détails techniques/, response.body)
    end
  end
end
