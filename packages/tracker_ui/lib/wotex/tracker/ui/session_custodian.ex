defmodule Wotex.Tracker.UI.SessionCustodian do
  @moduledoc """
  Optional host-owned custody for a successfully authenticated UI session.

  Ordinary browser hosts configure no custodian and remain volatile. A mobile
  host can persist its credential through platform secure storage without
  exposing the credential to controllers, LiveViews, cookies or assigns.
  """

  @type credential :: %{
          required(:token) => String.t(),
          required(:scope) => String.t(),
          required(:access) => map(),
          required(:session_id) => String.t()
        }

  @callback retain(context :: term(), credential()) :: :ok | {:error, term()}
  @callback release(context :: term(), credential()) :: :ok | {:error, term()}

  @doc false
  @spec retain(nil | {module(), term()}, credential()) :: :ok | :error
  def retain(nil, _credential), do: :ok
  def retain(custodian, credential), do: invoke(custodian, :retain, credential)

  @doc false
  @spec release(nil | {module(), term()}, credential()) :: :ok | :error
  def release(nil, _credential), do: :ok
  def release(custodian, credential), do: invoke(custodian, :release, credential)

  defp invoke({module, context}, function, credential)
       when is_atom(module) and is_map(credential) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 2) and
         apply(module, function, [context, credential]) == :ok,
       do: :ok,
       else: :error
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp invoke(_, _, _), do: :error
end
