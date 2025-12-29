require "test_helper"

class RunesControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get runes_index_url
    assert_response :success
  end
end
