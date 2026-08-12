defmodule SoundaiWeb.LayoutsTest do
  use SoundaiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the theme toggle" do
    html = render_component(&SoundaiWeb.Layouts.theme_toggle/1, %{})

    assert html =~ "data-phx-theme"
  end

  test "renders flash messages" do
    html = render_component(&SoundaiWeb.Layouts.flash_group/1, %{flash: %{"info" => "hello"}})

    assert html =~ "hello"
  end

  test "renders core icons" do
    html =
      render_component(&SoundaiWeb.CoreComponents.icon/1, %{name: "hero-check", class: "size-5"})

    assert html =~ "hero-check"
  end

  test "renders flash kinds" do
    html =
      render_component(&SoundaiWeb.CoreComponents.flash/1, %{
        flash: %{"info" => "hello"},
        kind: :info
      })

    assert html =~ "hello"

    html =
      render_component(&SoundaiWeb.CoreComponents.flash/1, %{
        flash: %{"error" => "oops"},
        kind: :error
      })

    assert html =~ "oops"
  end
end
