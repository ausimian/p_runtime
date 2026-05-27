defmodule PRuntime.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Unique registry so machines can be addressed by their P name rather than pid.
      {Registry, keys: :unique, name: PRuntime.Registry},
      # In-memory trace recorder used by tests to assert observable event traces.
      PRuntime.Trace
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PRuntime.Supervisor)
  end
end
