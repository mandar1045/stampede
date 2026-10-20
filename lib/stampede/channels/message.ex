defmodule Stampede.Channels.Message do
  @moduledoc false

  defstruct [:join_ref, :ref, :topic, :event, :payload]
end
