defmodule PRuntime.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Unique registry so machines can be addressed by their opaque id rather than pid.
      {Registry, keys: :unique, name: PRuntime.Registry},
      # In-memory trace recorder used by tests to assert observable event traces.
      PRuntime.Trace,
      # Subscription table for spec monitors; drives the synchronous fan-out of observed events.
      PRuntime.Specs,
      # Serializes `new MachineName(args)` so id allocation is race-free. It drives the
      # program's DynamicSupervisor (owned by the generated <Prefix>.Supervisor) by name.
      PRuntime.Spawner
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PRuntime.Supervisor)
  end
end
