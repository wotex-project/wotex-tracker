defmodule Wotex.Tracker.Service.Development.PassiveSimulator do
  @moduledoc """
  Deterministic development adapter for passive BLE scenarios.

  The module is compiled only in `dev` and `test`. It emits only caller-supplied
  admitted captures and stops after the finite list; it is never a production or
  hardware evidence fallback.
  """

  @behaviour Wotex.Tracker.Service.PassiveScanAdapter

  alias Wotex.Tracker.Service.PassiveAdvertisement

  @impl true
  def init(advertisements)
      when is_list(advertisements) and advertisements != [] and
             length(advertisements) <= 1_024 do
    with {:ok, admitted} <- admit(advertisements, []) do
      {:ok, :queue.from_list(admitted)}
    end
  end

  def init(_), do: {:error, :invalid_scenario}

  @impl true
  def next(queue) do
    case :queue.out(queue) do
      {{:value, advertisement}, remaining} -> {:ok, advertisement, remaining}
      {:empty, _} -> {:stop, queue}
    end
  end

  defp admit([], admitted), do: {:ok, Enum.reverse(admitted)}

  defp admit([value | rest], admitted) do
    case admit_one(value) do
      {:ok, advertisement} -> admit(rest, [advertisement | admitted])
      {:error, :invalid_advertisement} -> {:error, :invalid_scenario}
    end
  end

  defp admit_one(%PassiveAdvertisement{} = value), do: PassiveAdvertisement.validate(value)
  defp admit_one(value), do: PassiveAdvertisement.new(value)
end
