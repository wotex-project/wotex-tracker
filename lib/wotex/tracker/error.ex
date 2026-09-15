defmodule Wotex.Tracker.Error do
  @moduledoc """
  Stable, bounded boundary errors. Diagnostics contain no input values or exception text.

  Paths are JSON Pointers supplied by the implementation. Unknown codes, phases
  or invalid paths produce `invalid_error` instead of leaking arbitrary data.
  """

  @codes ~w(invalid_error invalid_input invalid_options invalid_limit limit_exceeded
    invalid_id invalid_json duplicate_id conflict dangling_reference evidence_cycle
    revision_mismatch association_mismatch invalid_profile invalid_predicate
    unknown_resolution invalid_decoder_result malformed_frame unsupported_version
    missing_capability missing_form invalid_mapping unsupported_model_feature
    invalid_security invalid_model invalid_td unavailable unauthorized unsupported)a
  @phases ~w(admission catalogue resolution decode evidence identity materialisation interface)a

  @type t :: %__MODULE__{code: atom(), phase: atom(), path: String.t()}
  @enforce_keys [:code, :phase]
  defstruct [:code, :phase, path: "/"]

  @doc "Constructs a redacted error; invalid diagnostic inputs become `invalid_error`."
  @spec new(atom(), atom(), String.t()) :: t()
  def new(code, phase, path \\ "/") do
    if code in @codes and phase in @phases and valid_path?(path) do
      %__MODULE__{code: code, phase: phase, path: path}
    else
      %__MODULE__{code: :invalid_error, phase: :admission}
    end
  end

  @doc "Projects errors to a stable JSON object, validating even forged structs."
  @spec to_map(term()) :: %{String.t() => String.t()}
  def to_map(%__MODULE__{code: code, phase: phase, path: path}) do
    error = new(code, phase, path)

    %{
      "code" => Atom.to_string(error.code),
      "phase" => Atom.to_string(error.phase),
      "path" => error.path
    }
  end

  def to_map(_), do: to_map(new(:invalid_error, :admission))

  defp valid_path?("/" <> _ = path), do: byte_size(path) <= 1024 and String.valid?(path)
  defp valid_path?(_), do: false
end
