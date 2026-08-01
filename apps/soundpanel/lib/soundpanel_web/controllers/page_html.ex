defmodule SoundpanelWeb.PageHTML do
  @moduledoc """
  Renders pages for PageController via embedded templates.
  """
  use SoundpanelWeb, :html

  embed_templates "page_html/*"
end
