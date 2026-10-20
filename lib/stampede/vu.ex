defmodule Stampede.VU do
  @moduledoc """
  A virtual user, given to `c:Stampede.Scenario.run/1`.

    * `:id` - a number from 1 upwards, unique within the run
    * `:iteration` - how many iterations the VU ran before this one
    * `:data` - what `c:Stampede.Scenario.setup/1` returned, or `nil`
  """

  @enforce_keys [:id]
  defstruct [:id, :data, iteration: 0]

  @type t :: %__MODULE__{id: pos_integer(), iteration: non_neg_integer(), data: term()}
end
