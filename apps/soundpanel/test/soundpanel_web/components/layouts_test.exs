defmodule SoundpanelWeb.LayoutsTest do
  use SoundpanelWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SoundpanelWeb.Layouts

  describe "theme_toggle/1" do
    test "renders the three theme options" do
      html = render_component(&Layouts.theme_toggle/1, %{})

      assert html =~ "data-phx-theme=\"system\""
      assert html =~ "data-phx-theme=\"light\""
      assert html =~ "data-phx-theme=\"dark\""
    end
  end

  describe "flash_group/1" do
    test "renders flash info and error groups" do
      html = render_component(&Layouts.flash_group/1, %{flash: %{"info" => "Hello"}})

      assert html =~ "flash-group"
      assert html =~ "aria-live=\"polite\""
    end

    test "does not require the id attribute" do
      html = render_component(&Layouts.flash_group/1, %{flash: %{}})

      assert html =~ "id=\"flash-group\""
    end
  end

  describe "app/1" do
    test "renders the navigation header and inner content" do
      html =
        render_component(&Layouts.app/1, %{
          flash: %{},
          inner_block: %{inner_block: fn _changed, _arg -> "Hello content" end}
        })

      assert html =~ "Get Started"
      assert html =~ "Hello content"
    end
  end
end
