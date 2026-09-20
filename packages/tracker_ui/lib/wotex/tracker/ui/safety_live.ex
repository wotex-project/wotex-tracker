defmodule Wotex.Tracker.UI.SafetyLive do
  @moduledoc """
  Presents the product's anti-stalking limits without requiring an account.

  This page intentionally makes no live service request. Safety guidance and
  incomplete hardware safeguards remain available when sign-in or the service
  is unavailable, and no presence on this page is presented as a detection.
  """

  use Phoenix.LiveView, log: false

  @impl true
  def mount(_, _, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <p class="eyebrow">Safety</p>
      <h1>Tracking safety and limitations</h1>
      <section class="panel" aria-labelledby="unwanted-tracker-title">
        <h2 id="unwanted-tracker-title">Not an unwanted-tracker detection network</h2>
        <p>
          WoTEx Tracker does not provide phone-vendor-scale unwanted-tracker detection. A missing
          alert here does not prove that no tracker is nearby, associated with an asset, or following
          a person.
        </p>
        <p>
          Hardware-specific unauthorized-association detection remains a required qualification
          gate. Until that evidence exists, this application must not be relied on as a personal
          safety detector.
        </p>
      </section>

      <section class="panel" aria-labelledby="controls-title">
        <h2 id="controls-title">Controls this deployment does provide</h2>
        <ul>
          <li>enrollment and later association require an explicit operator confirmation;</li>
          <li>current credentials can be reviewed and revoked, with successful access recorded;</li>
          <li>
            managed scope data can be inspected and deleted under the disclosed retention policy;
          </li>
          <li>ordinary screens use reviewed projections instead of raw hardware identifiers; and</li>
          <li>
            an armed or disarmed record is labelled as a service fact, not a physical-device action.
          </li>
        </ul>
        <p>
          Confirmation records an operator decision. It does not authenticate replayable radio
          identifiers, prove ownership of hardware, or grant permission to track another person.
        </p>
        <p>
          <a href="/access">Review access</a>
          · <a href="/privacy">Review retained data</a>
          · <a href="/setup">Review enrollment evidence</a>
        </p>
      </section>

      <section class="panel" aria-labelledby="response-title">
        <h2 id="response-title">If you suspect unauthorized tracking</h2>
        <ol>
          <li>Do not treat this application's status as proof that you are safe.</li>
          <li>
            Use the safety guidance and unwanted-tracker tools supplied by your phone and the
            relevant hardware manufacturer.
          </li>
          <li>
            If it is safe to do so, inspect the physical asset and preserve identifiers or evidence
            needed for a report before deleting records or resetting hardware.
          </li>
          <li>
            Revoke unexpected credentials, review the access journal, and remove unauthorized
            associations with an administrator.
          </li>
          <li>Contact local emergency services when there is immediate danger.</li>
        </ol>
      </section>

      <section class="panel" aria-labelledby="responsibility-title">
        <h2 id="responsibility-title">Consent and deployment responsibility</h2>
        <p>
          This project does not offer covert surveillance as a feature. Operators are responsible
          for consent, lawful deployment, physical labelling, credential custody, backup and export
          deletion, and the hardware-specific safeguards required for their use case.
        </p>
      </section>
    </main>
    """
  end
end
