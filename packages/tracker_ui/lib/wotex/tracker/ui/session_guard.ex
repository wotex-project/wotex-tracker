defmodule Wotex.Tracker.UI.SessionGuard do
  @moduledoc """
  Optional host-owned admission guard for shared LiveView sessions.

  Browser hosts normally configure no guard. A native loopback host can require
  an additional app-session binding without placing that capability in a view,
  socket assign or shared presentation module.
  """

  @callback valid_session?(context :: term(), session :: map()) :: boolean()
  @callback retained_session(context :: term(), session :: map()) :: map()
  @optional_callbacks retained_session: 2

  @doc "Admits an optional host guard while containing private host failures."
  @spec admit(nil | {module(), term()}, map()) :: :ok | :error
  def admit(nil, session) when is_map(session), do: :ok

  def admit({module, context}, session) when is_atom(module) and is_map(session) do
    if Code.ensure_loaded?(module) and
         function_exported?(module, :valid_session?, 2) and
         module.valid_session?(context, session) == true,
       do: :ok,
       else: :error
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  def admit(_, _), do: :error

  @doc "Returns the small host-owned binding that survives login/logout renewal."
  @spec retain(nil | {module(), term()}, map()) :: map()
  def retain(nil, _session), do: %{}

  def retain({module, context} = guard, session) when is_atom(module) and is_map(session) do
    with :ok <- admit(guard, session),
         true <- function_exported?(module, :retained_session, 2),
         retained when is_map(retained) <- module.retained_session(context, session),
         true <- retained?(retained) do
      retained
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  def retain(_, _), do: %{}

  defp retained?(retained) do
    map_size(retained) <= 8 and
      Enum.all?(retained, fn {key, value} ->
        is_binary(key) and byte_size(key) in 1..64 and is_binary(value) and
          byte_size(value) <= 256
      end)
  end
end
