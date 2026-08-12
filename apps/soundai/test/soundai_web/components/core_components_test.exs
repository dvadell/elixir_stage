defmodule SoundaiWeb.CoreComponentsTest do
  use SoundaiWeb.ConnCase, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  describe "icon/1" do
    test "renders a hero-prefixed icon" do
      html =
        render_component(&SoundaiWeb.CoreComponents.icon/1, %{
          name: "hero-x-mark",
          class: "w-4 h-4"
        })

      assert html =~ "hero-x-mark"
    end
  end

  describe "flash/1" do
    test "renders an info flash" do
      html =
        render_component(&SoundaiWeb.CoreComponents.flash/1, %{
          flash: %{"info" => "Saved"},
          kind: :info
        })

      assert html =~ "Saved"
      assert html =~ "hero-information-circle"
    end

    test "renders an error flash" do
      html =
        render_component(&SoundaiWeb.CoreComponents.flash/1, %{
          flash: %{"error" => "Failed"},
          kind: :error
        })

      assert html =~ "Failed"
      assert html =~ "hero-exclamation-circle"
    end

    test "renders an info flash without title" do
      html =
        render_component(&SoundaiWeb.CoreComponents.flash/1, %{
          flash: %{"info" => "Saved"},
          kind: :info,
          title: nil
        })

      assert html =~ "Saved"
      assert html =~ "<p>Saved</p>"
    end
  end

  defp render_button(opts) do
    inner = Keyword.fetch!(opts, :inner)
    rest = Keyword.get(opts, :rest, %{})

    inner_block = [
      %{
        __slot__: :inner_block,
        inner_block: fn _changed, _arg -> inner end
      }
    ]

    assigns = %{rest: rest, inner_block: inner_block}

    assigns =
      if opts[:variant] do
        Map.put(assigns, :variant, opts[:variant])
      else
        assigns
      end

    render_component(&SoundaiWeb.CoreComponents.button/1, assigns)
  end

  describe "button/1" do
    test "renders a plain button" do
      html = render_button(inner: ["Click me"], rest: %{type: "button"})

      assert html =~ "Click me"
      assert html =~ "type=\"button\""
    end

    test "renders a primary button" do
      html = render_button(inner: ["Primary"], rest: %{type: "button"}, variant: "primary")

      assert html =~ "Primary"
      assert html =~ "btn-primary"
    end

    test "renders a link button with href" do
      html = render_button(inner: ["Go"], rest: %{href: "/settings"})

      assert html =~ "href"
      assert html =~ "/settings"
    end

    test "renders a navigate button" do
      html = render_button(inner: ["Home"], rest: %{navigate: "/"})

      assert html =~ "Home"
    end

    test "renders a disabled button" do
      html = render_button(inner: ["Disabled"], rest: %{type: "button", disabled: true})

      assert html =~ "disabled"
    end
  end

  describe "input/1" do
    test "renders a text input" do
      form = to_form(%{"name" => "John"}, as: :user)

      html =
        render_component(&SoundaiWeb.CoreComponents.input/1, %{
          field: form[:name],
          type: "text",
          errors: []
        })

      assert html =~ "user[name]"
    end

    test "renders a hidden input" do
      form = to_form(%{"token" => "abc"}, as: :user)

      html =
        render_component(&SoundaiWeb.CoreComponents.input/1, %{
          field: form[:token],
          type: "hidden",
          errors: []
        })

      assert html =~ "type=\"hidden\""
    end

    test "renders a checkbox input" do
      form = to_form(%{"active" => true}, as: :user)

      html =
        render_component(&SoundaiWeb.CoreComponents.input/1, %{
          field: form[:active],
          type: "checkbox",
          errors: []
        })

      assert html =~ "type=\"checkbox\""
    end

    test "renders a select input" do
      form = to_form(%{"model" => "base"}, as: :settings)

      html =
        render_component(&SoundaiWeb.CoreComponents.input/1, %{
          field: form[:model],
          type: "select",
          options: [{"tiny", "Tiny"}, {"base", "Base"}, {"small", "Small"}],
          errors: []
        })

      assert html =~ "<select"
      assert html =~ "Tiny"
      assert html =~ "Base"
      assert html =~ "Small"
    end

    test "renders a textarea input" do
      form = to_form(%{"bio" => "Hello"}, as: :user)

      html =
        render_component(&SoundaiWeb.CoreComponents.input/1, %{
          field: form[:bio],
          type: "textarea",
          errors: []
        })

      assert html =~ "<textarea"
    end

    test "renders input with errors" do
      html =
        render_component(&SoundaiWeb.CoreComponents.input/1, %{
          name: "user[name]",
          id: "user_name",
          type: "text",
          value: "",
          errors: ["can't be blank"]
        })

      assert html =~ "can&#39;t be blank"
      assert html =~ "hero-exclamation-circle"
    end
  end
end
