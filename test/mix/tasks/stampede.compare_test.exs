defmodule Mix.Tasks.Stampede.CompareTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Stampede.Compare
  alias Stampede.{Reporter, Result}

  @moduletag :tmp_dir

  defp timing(p50) do
    %{type: :timing, count: 10, rate: 1.0, min: 1.0, mean: p50, p50: p50, p90: p50}
    |> Map.merge(%{p95: p50 * 2, p99: p50 * 3, max: p50 * 4})
  end

  defp result(scenario, metrics) do
    %Result{scenario: scenario, duration: 1_000, metrics: metrics}
  end

  defp write!(tmp_dir, name, results) do
    path = Path.join(tmp_dir, name)
    File.write!(path, ["[", Enum.map_intersperse(results, ",", &Reporter.to_json/1), "]"])
    path
  end

  defp compare(args) do
    {{status, output}, errors} = with_io(:stderr, fn -> with_io(fn -> status(args) end) end)
    {status, output, errors}
  end

  defp status(args) do
    Compare.run(args)
    0
  catch
    :exit, {:shutdown, status} -> status
  end

  test "prints how the percentiles of each scenario changed", %{tmp_dir: tmp_dir} do
    base = write!(tmp_dir, "base.json", [result(Lobby, %{"iteration" => timing(10.0)})])

    head =
      write!(tmp_dir, "head.json", [
        result(Lobby, %{
          "iteration" => timing(9.0),
          "channel.join" => timing(1.0),
          "iteration.errors" => %{type: :counter, count: 1, rate: 1.0}
        }),
        result(Checkout, %{"iteration" => timing(1.0)})
      ])

    {status, output, _errors} = compare([base, head])

    assert status == 0
    assert output =~ "Checkout is not in #{base}, skipping it"
    assert output =~ ~r/Lobby\n\s+metric\s+stat\s+base\s+head\s+change\n/
    assert output =~ ~r/iteration\s+p50\s+10\.00ms\s+9\.00ms\s+-10\.0%\n/
    assert output =~ ~r/iteration\s+p99\s+30\.00ms\s+27\.00ms\s+-10\.0%\n/
    refute output =~ "channel.join"
    refute output =~ "iteration.errors"
  end

  test "exits with status 1 when a percentile gets too slow", %{tmp_dir: tmp_dir} do
    base = write!(tmp_dir, "base.json", [result(Lobby, %{"iteration" => timing(10.0)})])
    head = write!(tmp_dir, "head.json", [result(Lobby, %{"iteration" => timing(12.0)})])

    {status, output, errors} = compare([base, head, "--max-regression", "10"])

    assert status == 1
    assert output =~ ~r/iteration\s+p95\s+20\.00ms\s+24\.00ms\s+\+20\.0%\s+FAIL\n/
    assert errors =~ "3 percentiles got more than 10.0% slower"

    {status, output, _errors} = compare([base, head, "--max-regression", "25"])

    assert status == 0
    refute output =~ "FAIL"
    assert output =~ "No percentile got more than 25.0% slower"
  end

  test "prints Markdown for pull request comments with --format markdown", %{tmp_dir: tmp_dir} do
    base = write!(tmp_dir, "base.json", [result(Lobby, %{"iteration" => timing(10.0)})])
    head = write!(tmp_dir, "head.json", [result(Lobby, %{"iteration" => timing(12.0)})])

    {status, output, _errors} =
      compare([base, head, "--format", "markdown", "--max-regression", "10"])

    assert status == 1

    assert output =~
             "### Lobby\n\n| metric | stat | base | head | change |\n|---|---|---:|---:|---:|\n"

    assert output =~ "| iteration | p50 | 10.00ms | 12.00ms | **+20.0% FAIL** |\n"

    empty = Path.join(tmp_dir, "empty.json")
    File.write!(empty, Reporter.to_json(result(Lobby, %{})))
    {_status, output, _errors} = compare([empty, empty, "--format", "markdown"])
    assert output =~ "No timings to compare."

    assert_raise Mix.Error, ~r/Expected --format to be text or markdown, got: html/, fn ->
      Compare.run([base, head, "--format", "html"])
    end
  end

  test "reads single results and raises on invalid files", %{tmp_dir: tmp_dir} do
    base = Path.join(tmp_dir, "base.json")
    File.write!(base, Reporter.to_json(result(Lobby, %{})))

    {status, output, _errors} = compare([base, base])
    assert status == 0
    assert output =~ "no timings to compare"

    assert_raise Mix.Error, ~r/Expected two result files/, fn -> Compare.run([base]) end

    assert_raise Mix.Error, ~r/Could not read .*missing.json/, fn ->
      Compare.run([base, Path.join(tmp_dir, "missing.json")])
    end

    invalid = Path.join(tmp_dir, "invalid.json")
    File.write!(invalid, "[{")
    assert_raise Mix.Error, ~r/Could not decode/, fn -> Compare.run([base, invalid]) end

    File.write!(invalid, ~s([{"name": "Lobby"}]))

    assert_raise Mix.Error, ~r/Expected .* to hold results/, fn ->
      Compare.run([base, invalid])
    end
  end
end
