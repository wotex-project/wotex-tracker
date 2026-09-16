defmodule Wotex.Tracker.UI.ErrorHTML do
  @moduledoc """
  Renders fixed browser error responses.

  The response depends only on the error template name. It does not include
  request parameters, credentials, exception messages, or storage diagnostics.
  Hosts can use it as their Phoenix endpoint's HTML error renderer.
  """

  @doc "Renders a bounded error without including credentials or diagnostic state."
  def render("403.html", _),
    do: "This request could not be verified. Reload the page and try again."

  def render("404.html", _), do: "This page is not available."
  def render(_, _), do: "The service could not complete this request."
end
