{:ok, _} = Ramal.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Ramal.TestRepo, :manual)

# The cluster tests start real nodes, which needs this VM to be distributed (and epmd). Without it they are skipped on a
# developer's machine, and CI, which sets CI, fails instead of skipping them without anyone noticing.
cluster? = Ramal.ClusterNodes.available?()

if not cluster? and System.get_env("CI") do
  raise "CI is set, so the cluster tests (test/ramal/cluster_nodes_test.exs) must run, but this VM cannot run " <>
          "distributed: #{Ramal.ClusterNodes.unavailable_reason()}. Install Erlang with epmd (setup-beam does), " <>
          "or unset CI to skip them."
end

ExUnit.start(exclude: if(cluster?, do: [], else: [:cluster]))
