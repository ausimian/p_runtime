defmodule PRuntime.Spawner do
  @moduledoc """
  Serializes P machine creation (`new MachineName(args)`).

  Every `new` routes here. The spawner picks the lowest free id for the machine's base name
  (so the first `Pinger` registers as `"Pinger"`, a concurrent second as `"Pinger:1"`, and a
  later one reuses `"Pinger"` once the first has halted), then starts it under the program's
  `DynamicSupervisor`.

  Doing this in a single GenServer makes id allocation deterministic and race-free:
  `DynamicSupervisor.start_child/2` blocks until the child's `init` has run — and the child
  registers its id during `init` — so by the time the next `create/3` allocates, the previous
  id is already visible in the registry. (A machine's `init` only queues its entry event, never
  runs user code, so it cannot call back into the spawner and deadlock.)
  """
  use GenServer

  # Well-known name of the per-program DynamicSupervisor, started by the generated
  # `<Prefix>.Supervisor`. Resolved at call time, so the spawner can boot before it exists.
  @machine_supervisor PRuntime.MachineSupervisor

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Create machine `module` (base name `name`) with entry payload `args`; returns its id."
  @spec create(module(), String.t(), term()) :: PRuntime.machine()
  def create(module, name, args) do
    GenServer.call(__MODULE__, {:create, module, name, args})
  end

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:create, module, name, args}, _from, state) do
    id = allocate_id(name)
    {:ok, _pid} =
      DynamicSupervisor.start_child(@machine_supervisor, {module, %{id: id, args: args}})

    {:reply, id, state}
  end

  # Lowest unused id for `name`: the bare name if free, else `name:1`, `name:2`, … Tied to
  # current registry occupancy (not a monotonic counter), so ids are reused after machines halt
  # and single-instance traces stay readable.
  defp allocate_id(name) do
    Enum.reduce_while(Stream.iterate(0, &(&1 + 1)), nil, fn i, _ ->
      id = if i == 0, do: name, else: "#{name}:#{i}"

      case Registry.lookup(PRuntime.Registry, id) do
        [] -> {:halt, id}
        _ -> {:cont, nil}
      end
    end)
  end
end
