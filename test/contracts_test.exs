Code.require_file("../scripts/contracts.exs", __DIR__)

defmodule WotexTracker.ContractsTest do
  use ExUnit.Case, async: true
  alias WotexTracker.Contracts

  setup do
    {:ok, catalogue} = Contracts.parse(File.read!("docs/specs/catalogue.yaml"))
    %{catalogue: catalogue}
  end

  test "malformed catalogue shapes fail explicitly" do
    for value <- [nil, [], %{}, %{"contracts" => 1}] do
      assert {:error, :invalid_catalogue} = Contracts.validate(value, ".")
    end
  end

  test "repository contracts and links resolve" do
    assert :ok = Contracts.check(File.cwd!())
  end

  test "duplicate YAML keys cannot be lost in map conversion" do
    assert {:error, :duplicate_key} = Contracts.parse("a: 1\na: 2\n")
    assert {:error, :duplicate_key} = Contracts.parse("a:\n  b: 1\n  b: 2\n")
    assert {:error, :invalid_yaml} = Contracts.parse("a: [")
    assert {:error, :document_count} = Contracts.parse("---\na: 1\n---\nb: 2")
  end

  test "duplicates, unresolved references and missing files fail", %{catalogue: c} do
    [first | rest] = c["contracts"]
    assert {:error, _} = Contracts.validate(%{c | "contracts" => [first, first | rest]}, ".")

    for changed <- [%{first | "depends_on" => ["WTR.99"]}, %{first | "file" => "absent.md"}] do
      assert {:error, _} = Contracts.validate(%{c | "contracts" => [changed | rest]}, ".")
    end
  end

  test "delivery graph is distinct from cyclic contract references", %{catalogue: c} do
    [first | rest] = c["delivery_targets"]
    cycle = %{first | "requires" => ["integrated_product"]}

    assert {:error, :delivery_cycle} =
             Contracts.validate(%{c | "delivery_targets" => [cycle | rest]}, ".")

    for change <- [
          %{first | "implementation_status" => "accepted", "evidence_refs" => []},
          %{first | "implementation_status" => "invented"},
          %{first | "required_for_product" => false},
          %{first | "evidence_refs" => ["missing"]}
        ] do
      assert {:error, _} = Contracts.validate(%{c | "delivery_targets" => [change | rest]}, ".")
    end
  end

  test "dependency installation defines no Tracker application callback" do
    assert [] == Application.spec(:wotex_tracker, :mod)
  end
end
