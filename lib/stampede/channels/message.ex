defmodule Stampede.Channels.Message do
  @moduledoc """
  A message of the Phoenix Channels protocol, as a
  `Stampede.Channels.Serializer` encodes and decodes it.

  The `payload` is decoded JSON, or `{:binary, data}` for a binary payload.
  Replies have the `"phx_reply"` event, and a payload with the `"status"` and
  the `"response"`.
  """

  defstruct [:join_ref, :ref, :topic, :event, :payload]

  @type t :: %__MODULE__{
          join_ref: String.t() | nil,
          ref: String.t() | nil,
          topic: String.t(),
          event: String.t(),
          payload: term()
        }
end
