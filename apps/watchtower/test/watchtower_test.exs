defmodule WatchtowerTest do
  use ExUnit.Case
  doctest Watchtower

  test "greets the world" do
    assert Watchtower.hello() == :world
  end
end
