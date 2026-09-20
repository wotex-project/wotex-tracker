alias Wotex.Tracker.Nerves.RecoveryValidation
alias Wotex.Tracker.Service.Codec

case RecoveryValidation.run(System.argv()) do
  {:ok, result} ->
    IO.puts(Codec.encode!(result))

  {:error, reason} ->
    IO.puts(:stderr, Codec.encode!(%{"error" => Atom.to_string(reason)}))
    System.halt(1)
end
