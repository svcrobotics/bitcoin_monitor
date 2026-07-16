# frozen_string_literal: true

require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test "uses the Tansa browser title" do
    get root_path

    assert_response :success
    assert_select "title", text: "Tansa"
  end
end
