defmodule Stampede.Runner.RateTest do
  use ExUnit.Case, async: true

  alias Stampede.Test.{Arriving, Slow}

  describe "rates" do
    test "start iterations at the rate and reuse idle VUs" do
      result = Stampede.run(Arriving, rate: 50, duration: 1_000)

      assert result.metrics["iteration"].count in 45..50
      refute Map.has_key?(result.metrics, "iterations.dropped")

      vus = for "arriving." <> id <- Map.keys(result.metrics), do: id
      assert length(vus) < 10
    end

    test "drop iterations when every VU is busy" do
      result = Stampede.run(Slow, rate: 100, duration: 500, max_vus: 2)

      assert result.metrics["iterations.dropped"].count > 30
      assert result.metrics["iteration"].count <= 6
    end
  end
end
