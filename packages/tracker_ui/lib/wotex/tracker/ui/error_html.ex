defmodule Wotex.Tracker.UI.ErrorHTML do
  @moduledoc "Fixed error responses that never render request or exception contents."
  @doc "Renders a bounded error without including credentials or diagnostic state."
  def render("403.html", _),
    do: "This request could not be verified. Reload the page and try again."

  def render("404.html", _), do: "This page is not available."
  def render(_, _), do: "The service could not complete this request."
end
