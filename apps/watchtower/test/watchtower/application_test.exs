# Tests may hit their own local health endpoint directly; no wrapper needed.
# credo:disable-for-this-file Credo.Check.Extra.NoDirectThirdPartyCalls
defmodule Watchtower.ApplicationTest do
  use ExUnit.Case

  @port Application.compile_env(:watchtower, :health_port, 4003)

  test "start/2 boots the DNS cluster member and the health server" do
    # The application was auto-started by the test VM; stop it so the
    # callback is exercised and the supervisor is recreated under the test
    # process instead of the boot-time one.
    :ok = Application.stop(:watchtower)

    assert {:ok, pid} = Watchtower.Application.start(:normal, [])
    assert Process.whereis(Watchtower.Supervisor) == pid
    children = :supervisor.which_children(Watchtower.Supervisor)
    # `which_children/1` ids match the child specs; bare-module specs resolve
    # to the module itself, while anonymous specs keep the full spec tuple.
    ids =
      Enum.map(children, fn
        {{mod, _}, _child, _type, _sf} -> mod
        {id, _child, _type, _sf} -> id
      end)

    assert Bandit in ids
    assert DNSCluster in ids

    # The Bandit server serves the liveness endpoint on the configured port.
    assert {:ok, %Req.Response{status: 200, body: "ok"}} =
             Req.get("http://127.0.0.1:#{@port}/health")
  end
end
