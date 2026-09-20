defmodule Wotex.Tracker.UI.AccessibilityAuditTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Wotex.Tracker.UI.AccessibilityAudit

  test "accepts the semantic baseline" do
    html = """
    <html lang="en">
      <body>
        <main>
          <h1>Accessible page</h1>
          <section aria-labelledby="details-title">
            <h2 id="details-title">Details</h2>
            <label for="name">Name</label>
            <input id="name" type="text">
            <button type="button">Save</button>
            <a href="/next" aria-label="Next page"></a>
            <div role="region" aria-labelledby="records-title">
              <h3 id="records-title">Records</h3>
              <table><caption>Exact records</caption><tbody></tbody></table>
            </div>
            <svg role="img" aria-label="One observed point"></svg>
            <img src="decoration.png" alt="">
          </section>
        </main>
      </body>
    </html>
    """

    assert :ok = AccessibilityAudit.audit(html)
  end

  test "reports structural, naming and reference failures together" do
    html = """
    <html>
      <body>
        <main id="duplicate">
          <h1>Broken page</h1>
          <h3>Skipped level</h3>
          <input id="duplicate" type="text">
          <button type="button"></button>
          <a href="/empty"></a>
          <div role="region"></div>
          <div aria-describedby="missing"></div>
          <table></table>
          <svg aria-label="Missing role"></svg>
          <img src="missing-alt.png">
        </main>
        <main><h1>Duplicate landmark</h1></main>
      </body>
    </html>
    """

    assert {:error, failures} = AccessibilityAudit.audit(html)
    joined = Enum.join(failures, "\n")
    assert joined =~ "expected 1 main, found 2"
    assert joined =~ "expected 1 h1, found 2"
    assert joined =~ "html has no language"
    assert joined =~ "heading order jumps from h1 to h3"
    assert joined =~ "duplicate ids: duplicate"
    assert joined =~ "broken aria-describedby: missing"
    assert joined =~ "input#duplicate has no accessible label"
    assert joined =~ "button has no accessible name"
    assert joined =~ "a has no accessible name"
    assert joined =~ "table has no caption"
    assert joined =~ "svg has no accessible alternative"
    assert joined =~ "img has no accessible alternative"
    assert joined =~ "div region has no accessible name"
  end
end
