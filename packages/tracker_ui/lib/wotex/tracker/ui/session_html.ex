defmodule Wotex.Tracker.UI.SessionHTML do
  @moduledoc false
  use Phoenix.Component

  def new(assigns) do
    ~H"""
    <main id="main" class="sign-in">
      <p class="eyebrow">Your infrastructure. Your assets.</p>
      <h1>Connect to your tracker service</h1>
      <p>Use a credential and scope provided by this service's operator.</p>
      <p :if={@message} class="notice" role="alert">{@message}</p>
      <.form for={%{}} id="sign-in" action="/session" method="post">
        <label for="scope">Scope</label>
        <input id="scope" name="scope" required maxlength="128" autocomplete="organization" />
        <label for="token">Access token</label>
        <input
          id="token"
          name="token"
          type="password"
          required
          maxlength="256"
          autocomplete="current-password"
        />
        <button type="submit">Sign in</button>
      </.form>
      <p class="muted">Credentials stay with this service. Sign out on shared displays.</p>
    </main>
    """
  end
end
