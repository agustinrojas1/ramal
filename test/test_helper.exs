{:ok, _} = Ramal.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Ramal.TestRepo, :manual)
ExUnit.start()
