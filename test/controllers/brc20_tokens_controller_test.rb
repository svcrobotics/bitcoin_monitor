require "test_helper"

class Brc20TokensControllerTest < ActionDispatch::IntegrationTest
  test "should get show" do
    get brc20_tokens_show_url
    assert_response :success
  end
end
