defmodule Mix.Tasks.Stampede.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "creates a scenario to start from, named after the project" do
    test_project()
    |> Igniter.compose_task("stampede.install", [])
    |> assert_creates("loadtest/home.exs", fn contents ->
      assert contents =~ "defmodule Test.Load.Home do"
      assert contents =~ ~s{Stampede.HTTP.get("http://localhost:4000/")}
    end)
    |> assert_has_notice(&(&1 =~ "mix stampede.run loadtest/home.exs --dashboard"))
  end

  test "keeps a scenario that already exists" do
    test_project(files: %{"loadtest/home.exs" => "# mine\n"})
    |> Igniter.compose_task("stampede.install", [])
    |> assert_unchanged("loadtest/home.exs")
  end
end
