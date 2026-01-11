module UiModeHelper
  def simple_mode?
    session[:ui_mode] != "trader"
  end

  def trader_mode?
    session[:ui_mode] == "trader"
  end
end
