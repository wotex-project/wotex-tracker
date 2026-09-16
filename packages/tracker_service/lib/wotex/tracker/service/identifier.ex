defmodule Wotex.Tracker.Service.Identifier do
  @moduledoc false

  import Bitwise

  def uuid do
    <<a::48, version::16, variant::16, b::48>> = :crypto.strong_rand_bytes(16)

    hex =
      Base.encode16(
        <<a::48, (version &&& 0x0FFF) ||| 0x4000::16, (variant &&& 0x3FFF) ||| 0x8000::16,
          b::48>>,
        case: :lower
      )

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary>> =
      hex

    Enum.join([a, b, c, d, e], "-")
  end

  def operation?(value) when is_binary(value) and byte_size(value) == 36,
    do:
      Regex.match?(
        ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
        value
      )

  def operation?(_), do: false
end
