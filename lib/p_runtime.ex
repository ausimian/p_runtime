defmodule PRuntime do
  @moduledoc """
  Runtime support for P programs compiled to Elixir (the `p_runtime` library).

  Owns the cross-cutting pieces that do *not* vary with the `.p` source: the registry,
  structured logging/tracing, the send wrapper (with halt-aware semantics), and helpers
  that build `:gen_statem` return tuples while recording the corresponding trace entry.

  This mirrors how PChecker works: generated machine modules call these helpers, and
  logging happens here as a side effect — never inline in generated code. See DESIGN.md.

  ## Scope so far

  M1–M2: machine creation, state entry, dequeue, `goto` (with entry payload), `raise halt`,
  and a `send`/cast wrapper. M3 adds dynamic creation (`new`, via `PRuntime.create/3` and the
  `PRuntime.Spawner`) and resolves cross-machine sends through the registry by opaque id.
  Specs/announce and the full PObserve log shape arrive in later milestones.
  """

  alias PRuntime.Trace

  @typedoc """
  A P machine's identity: an opaque id allocated when the machine is created.

  Today it is a `String.t()` (the machine's registry key, e.g. `"Pinger"` or `"Pinger:1"`),
  but generated code must treat it as opaque so a later distributed form (`{node, id}`)
  stays non-breaking — see DESIGN.md Open Question 5. Machines are addressed by this id, not
  by pid, so identity is stable across the (transient) process lifetime.
  """
  @type machine :: term()

  # ---- lifecycle / logging (side-effecting calls from generated code) ----

  @doc "Record that `machine` was created."
  @spec created(machine()) :: :ok
  def created(machine), do: Trace.record({:create, machine})

  # ---- creation (P `new MachineName(args)`) ----

  @doc """
  Create machine `module` (P base name `name`) carrying entry payload `args`; returns its id.

  Routed through `PRuntime.Spawner` so id allocation is serialized and race-free, and so the
  child is started under the program's `DynamicSupervisor`. The call blocks until the new
  machine's `init` has run (and registered), so the returned id is immediately addressable.
  """
  @spec create(module(), String.t(), term()) :: machine()
  def create(module, name, args), do: PRuntime.Spawner.create(module, name, args)

  @doc "Record that `machine` entered `state`."
  @spec entered(machine(), atom()) :: :ok
  def entered(machine, state), do: Trace.record({:enter, machine, state})

  @doc "Record that `machine` dequeued `event` while in `state`."
  @spec dequeued(machine(), atom(), atom()) :: :ok
  def dequeued(machine, state, event), do: Trace.record({:dequeue, machine, state, event})

  # ---- transitions: build the :gen_statem return AND log it ----

  @doc """
  Build the `:gen_statem` return for `goto target` (optionally carrying a `payload`).

  Transitions to `target` and queues the synthetic `{:__entry__, payload}` internal event so the
  target's entry handler runs *in the new state* and receives the goto payload, preserving P's
  entry-runs-on-arrival semantics across every transition. `payload` is `nil` for a payload-less
  `goto`.

  A `goto` to the *current* state is a real re-entry in P (exit then entry run again), but
  `:gen_statem` treats `{:next_state, S, _}` with `S` unchanged as "no state change" and skips the
  `state_enter` callback. We therefore use `:repeat_state` for a self-transition, which re-runs
  `state_enter` (so the entry is observed) while still processing the queued `{:__entry__}` event.
  """
  @spec goto(machine(), atom(), atom(), term(), term()) :: tuple()
  def goto(machine, from, target, data, payload \\ nil) do
    Trace.record({:goto, machine, from, target})
    enter = {:next_event, :internal, {:__entry__, payload}}

    if from == target do
      {:repeat_state, data, [enter]}
    else
      {:next_state, target, data, [enter]}
    end
  end

  @doc """
  Build the `:gen_statem` return for `raise halt`.

  Maps to a normal stop. Per P semantics (and PChecker), exit handlers do NOT run on
  halt, and sends to a halted machine are dropped — see `send_event/4`.
  """
  @spec halt(machine(), atom(), term()) :: tuple()
  def halt(machine, state, data) do
    Trace.record({:halt, machine, state})
    {:stop, :normal, data}
  end

  # ---- send ----

  @doc """
  Send event `name` (with optional `payload`) to `target`.

  `target` is an opaque machine id (resolved to a pid via the registry) or, for test
  harnesses, a raw pid. Async cast, matching P's non-blocking `send`. If the target has
  halted — its id is no longer registered, or its pid is dead — the cast is dropped and a
  `:send_to_halted` entry is logged instead, mirroring the C# runtime, where enqueue to a
  halted machine returns `Dropped`.
  """
  @spec send_event(machine(), machine() | pid(), atom(), term()) :: :ok
  def send_event(from, target, name, payload \\ nil) do
    Trace.record({:send, from, target, name})

    case resolve(target) do
      {:ok, pid} -> :gen_statem.cast(pid, {:p_event, name, payload})
      :halted -> Trace.record({:send_to_halted, from, target, name})
    end

    :ok
  end

  # Resolve a send target to a live pid. A pid is used directly (test harnesses pass pids);
  # any other term is treated as a registry id. Either way a dead/unregistered target yields
  # :halted so the send is dropped rather than crashing the sender.
  @spec resolve(machine() | pid()) :: {:ok, pid()} | :halted
  defp resolve(pid) when is_pid(pid), do: if(Process.alive?(pid), do: {:ok, pid}, else: :halted)

  defp resolve(id) do
    case Registry.lookup(PRuntime.Registry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :halted
    end
  end
end
