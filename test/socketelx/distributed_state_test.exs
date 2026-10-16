defmodule Socketelx.Backend.Distributed.StateTest do
  use ExUnit.Case, async: true

  alias Socketelx.Backend.Distributed.State

  # Members are just pids; any distinct pids will do.
  defp member, do: spawn(fn -> Process.sleep(:infinity) end)

  test "a channel is occupied by the first member and vacated by the last" do
    {a, b} = {member(), member()}
    s = State.new()

    assert {s, true} = State.join(s, a, "news")
    assert {s, false} = State.join(s, b, "news")
    # reporting the same member twice changes nothing
    assert {s, false} = State.join(s, a, "news")

    assert {s, false} = State.leave(s, a, "news")
    assert {s, true} = State.leave(s, b, "news")
    # leaving something never joined is a no-op, not a bogus vacated
    assert {_s, false} = State.leave(s, b, "news")
  end

  test "presence: a user is new once, however many connections and nodes they have" do
    {a, b} = {member(), member()}
    s = State.new()

    assert {s, true} = State.presence_add(s, a, "presence-r", "s1", "u1", %{n: 1})
    assert {s, false} = State.presence_add(s, b, "presence-r", "s2", "u1", %{n: 1})
    assert {s, true} = State.presence_add(s, b, "presence-r", "s3", "u2", %{n: 2})

    assert State.members(s, "presence-r") |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["u1", "u2"]

    # u1 still has s2, so s1 leaving is not their last connection
    assert {s, {false, "u1"}} = State.presence_remove(s, "presence-r", "s1")
    assert {s, {true, "u1"}} = State.presence_remove(s, "presence-r", "s2")
    assert {_s, {false, nil}} = State.presence_remove(s, "presence-r", "unknown")
  end

  test "dropping a dead member announces exactly what left the cluster" do
    {a, b} = {member(), member()}
    s = State.new()
    {s, _} = State.join(s, a, "news")
    {s, _} = State.join(s, b, "news")
    {s, _} = State.join(s, a, "only-a")
    {s, _} = State.presence_add(s, a, "presence-r", "s1", "u1", %{})
    {s, _} = State.presence_add(s, b, "presence-r", "s2", "u1", %{})
    {s, _} = State.presence_add(s, a, "presence-r", "s3", "u2", %{})

    {s, announcements} = State.drop_member(s, a)

    # u2 only lived on a; u1 is still on b; "news" is still occupied; "only-a" is not
    assert {:member_removed, "presence-r", "u2"} in announcements
    refute {:member_removed, "presence-r", "u1"} in announcements
    assert {:channel_vacated, "only-a"} in announcements
    refute {:channel_vacated, "news"} in announcements
    assert length(announcements) == 2

    assert State.member_pids(s) == MapSet.new([b])
  end

  test "a silent sync changes state without announcing; an announcing one reports the difference" do
    a = member()
    s = State.new()

    {s, anns} = State.replace_member(s, a, ["c1"], [{"presence-r", "s1", "u1", %{}}], false)
    assert anns == []
    assert State.members(s, "presence-r") == [{"u1", %{}}]

    # the node now reports a different picture, and this time it is announced
    {s, anns} = State.replace_member(s, a, ["c2"], [{"presence-r", "s9", "u9", %{}}], true)
    assert {:channel_vacated, "c1"} in anns
    assert {:channel_occupied, "c2"} in anns
    assert {:member_removed, "presence-r", "u1"} in anns
    assert {:member_added, "presence-r", "u9", %{}} in anns
    assert State.members(s, "presence-r") == [{"u9", %{}}]
  end

  test "replicated operations rebuild the same state as the leader's results" do
    {a, b} = {member(), member()}

    ops = [
      {:join, a, "news"},
      {:join, b, "news"},
      {:padd, a, "presence-r", "s1", "u1", %{}},
      {:padd, b, "presence-r", "s2", "u2", %{}},
      {:prem, "presence-r", "s1"},
      {:leave, a, "news"},
      {:drop, b}
    ]

    assert Enum.reduce(ops, State.new(), &State.apply_op(&2, &1)) == State.new()
  end
end
