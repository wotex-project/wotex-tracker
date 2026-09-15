defmodule Wotex.Tracker.ErrorTest do
  use ExUnit.Case, async: true
  alias Wotex.Tracker.Error

  test "fixed error projection carries no raw input" do
    assert Error.to_map(Error.new(:invalid_input, :admission, "/payload")) ==
             %{"code" => "invalid_input", "phase" => "admission", "path" => "/payload"}

    for {code, phase, path} <- [
          {:secret, :admission, "/"},
          {:invalid_input, :secret, "/"},
          {:invalid_input, :admission, ""},
          {:invalid_input, :admission, 1},
          {:invalid_input, :admission, <<?/, 255>>},
          {:invalid_input, :admission, "/" <> String.duplicate("a", 1024)}
        ] do
      assert %Error{code: :invalid_error, path: "/"} = Error.new(code, phase, path)
    end

    assert Error.to_map(:secret) == Error.to_map(Error.new(:invalid_error, :admission))

    assert Error.to_map(%Error{code: :secret, phase: :secret, path: "credential"}) ==
             Error.to_map(Error.new(:invalid_error, :admission))

    for size <- [1022, 1023] do
      assert %Error{code: :invalid_input} =
               Error.new(:invalid_input, :admission, "/" <> String.duplicate("x", size))
    end
  end
end
