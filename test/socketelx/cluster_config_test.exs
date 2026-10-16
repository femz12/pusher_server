defmodule Socketelx.ClusterConfigTest do
  # Reads and writes the OS environment, so it must not run alongside other tests.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Socketelx.Config

  @env ~w(SOCKETELX_CLUSTER SOCKETELX_CLUSTER_NODES SOCKETELX_CLUSTER_DNS
          SOCKETELX_CLUSTER_NODE_BASENAME SOCKETELX_REDIS_URL
          PUSHER_CLUSTER PUSHER_CLUSTER_NODES PUSHER_REDIS_URL)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  test "cluster mode is off by default and uses the local backend" do
    config = Config.resolve(:cluster_cfg_default, [])
    assert config.cluster == nil
    assert config.backend == Socketelx.Backend.Local
    assert config.cluster_nodes == []
  end

  test "the :cluster option selects the distributed backend" do
    config = Config.resolve(:cluster_cfg_opt, cluster: :erlang)
    assert config.cluster == :erlang
    assert config.backend == Socketelx.Backend.Distributed
  end

  test "environment variables turn it on and list the peers" do
    System.put_env("SOCKETELX_CLUSTER", "erlang")
    System.put_env("SOCKETELX_CLUSTER_NODES", "socketelx@a, socketelx@b ,")
    System.put_env("SOCKETELX_CLUSTER_DNS", "tasks.socketelx")
    System.put_env("SOCKETELX_CLUSTER_NODE_BASENAME", "chat")

    config = Config.resolve(:cluster_cfg_env, [])
    assert config.backend == Socketelx.Backend.Distributed
    assert config.cluster_nodes == [:socketelx@a, :socketelx@b]
    assert config.cluster_dns == "tasks.socketelx"
    assert config.cluster_node_basename == "chat"
  end

  test "the older PUSHER_* spelling still works, and SOCKETELX_* wins" do
    System.put_env("PUSHER_CLUSTER", "erlang")
    assert Config.resolve(:cluster_cfg_old, []).backend == Socketelx.Backend.Distributed

    System.put_env("PUSHER_CLUSTER_NODES", "old@host")
    System.put_env("SOCKETELX_CLUSTER_NODES", "new@host")
    assert Config.resolve(:cluster_cfg_both, []).cluster_nodes == [:new@host]
  end

  test "options accept a list of atoms or strings for the peers" do
    config = Config.resolve(:cluster_cfg_list, cluster: :erlang, cluster_nodes: [:a@h, "b@h"])
    assert config.cluster_nodes == [:a@h, :b@h]
  end

  test "Redis and the cluster mode cannot be combined" do
    assert_raise ArgumentError, ~r/either a Redis URL or `cluster: :erlang`/, fn ->
      Config.resolve(:cluster_cfg_clash, cluster: :erlang, redis_url: "redis://localhost:6379")
    end

    System.put_env("SOCKETELX_CLUSTER", "erlang")
    System.put_env("SOCKETELX_REDIS_URL", "redis://localhost:6379")

    assert_raise ArgumentError, fn -> Config.resolve(:cluster_cfg_clash_env, []) end
  end

  test "an unknown cluster mode is rejected rather than ignored" do
    assert_raise ArgumentError, ~r/unknown cluster mode/, fn ->
      Config.resolve(:cluster_cfg_bad, cluster: :gossip)
    end

    System.put_env("SOCKETELX_CLUSTER", "redis")

    assert_raise ArgumentError, ~r/unknown cluster mode/, fn ->
      Config.resolve(:cluster_cfg_bad2, [])
    end
  end
end
