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
  M4 adds the queue manipulations: `defer` (`:postpone`), `ignore`, and non-halt `raise`
  (front-of-queue re-delivery). M5 adds spec monitors: each `spec` is a separate `:gen_statem`
  that registers its observed events via `observes/2`, and the synchronous fan-out (`announce/3`
  and the fan-out built into `send_event/4`) mirrors observed events to those specs at send time
  — see `PRuntime.Specs`. Monitoring is opt-in via the `:p_runtime, :monitoring` flag (default
  off): when off, the fan-out short-circuits and sends cost nothing extra, so a production
  deployment runs the same machines without paying for spec delivery. Trace entries are also
  emitted as structured log lines (`PRuntime.Log`). M7 surfaces failures faithfully: an event a
  state cannot handle goes through `unhandled_event/3` (records + logs + raises
  `PRuntime.UnhandledEvent`, mirroring P's abort) instead of being silently dropped, and a
  machine's `terminate/3` calls `terminated/3` so an abnormal crash is recorded/logged with context
  rather than vanishing into a bare `:gen_statem` report.
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

  @doc """
  Register that spec `spec_id` observes `events`.

  Called from a spec's `init` (specs are passive `:gen_statem` monitors). Populates the
  `PRuntime.Specs` subscription table that the fan-out reads, so observed events are mirrored to
  the spec from the moment it has started.
  """
  @spec observes(machine(), [atom()]) :: :ok
  def observes(spec_id, events), do: PRuntime.Specs.register(spec_id, events)

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

  @doc """
  Report an event `machine` received but cannot handle in `state`.

  P aborts a machine that dequeues an event with no handler/`defer`/`ignore` in the current state.
  The generated `handle_event/4` catch-all routes such a P event here (stray non-P messages are
  ignored, not funnelled here). The unhandled event is recorded to the trace and logged at `:error`
  *before* raising `PRuntime.UnhandledEvent`, so it is visible even if the raise is later swallowed.
  Never returns.
  """
  @spec unhandled_event(machine(), atom(), atom()) :: no_return()
  def unhandled_event(machine, state, event) do
    Trace.record({:unhandled, machine, state, event})
    require Logger
    Logger.error("P machine #{inspect(machine)} received unhandled event #{inspect(event)} in state #{inspect(state)}")
    raise PRuntime.UnhandledEvent, machine: machine, state: state, event: event
  end

  @doc """
  Surface a machine/spec process terminating, called from the generated `terminate/3` callback.

  A clean stop is silent: a normal `raise halt` is already traced by `halt/3`, `:shutdown` is the
  supervisor stopping the tree, and a `PRuntime.SafetyViolation`/`PRuntime.UnhandledEvent` was
  already recorded and logged at its source. Any *other* reason is an abnormal crash — recorded to
  the trace as `{:crash, machine, state, reason}` and logged at `:error` with the machine and state,
  so a crash is legible context rather than a bare `:gen_statem` report. Per DESIGN.md Open
  Question 3, an abnormal crash is surfaced (not silently respawned); machines do not restart.
  """
  @spec terminated(machine(), atom(), term()) :: :ok
  def terminated(_machine, _state, reason) when reason in [:normal, :shutdown], do: :ok
  def terminated(_machine, _state, {:shutdown, _}), do: :ok
  def terminated(_machine, _state, {%PRuntime.SafetyViolation{}, _stack}), do: :ok
  def terminated(_machine, _state, {%PRuntime.UnhandledEvent{}, _stack}), do: :ok
  def terminated(_machine, _state, {%PRuntime.DynamicError{}, _stack}), do: :ok

  def terminated(machine, state, reason) do
    Trace.record({:crash, machine, state, reason})
    require Logger
    Logger.error("P machine #{inspect(machine)} crashed in state #{inspect(state)}: #{inspect(reason)}")
    :ok
  end

  @doc """
  Check a P `assert`: succeed if `condition` holds, otherwise raise a `PRuntime.SafetyViolation`.

  P `assert` is a safety check usable in machines and specs alike, so all generated `assert`s route
  here rather than emitting a bare `raise`. On failure the violation is recorded to the trace and
  logged at `:error` *before* raising, so it is visible even where the raise is swallowed (e.g. the
  spec fan-out flush deliberately does not let a violating monitor cascade into the sender). `message`
  is the assertion message the compiler built, already prefixed with the P source location.
  """
  @spec assert(machine(), boolean(), String.t()) :: :ok
  def assert(_machine, true, _message), do: :ok

  def assert(machine, _condition, message) do
    Trace.record({:assert_failed, machine, message})
    require Logger
    Logger.error("P safety violation in #{inspect(machine)}: #{message}")
    raise PRuntime.SafetyViolation, machine: machine, message: message
  end

  # ---- collection access (enforce P's index/key rules) ----
  #
  # P defines runtime error cases for collection access that the permissive Elixir built-ins do not
  # signal: `Map.get` returns nil on a missing key, `Enum.at` returns nil out of range, and
  # `List.insert_at`/`replace_at`/`delete_at` clamp an out-of-range index. Generated code routes
  # collection reads/writes through these helpers so a P dynamic error aborts the machine via
  # `dynamic_error/2` (mirroring the C# runtime) instead of limping on with a wrong value.

  @doc """
  Read element `index` of sequence `seq` (P `seq[index]`).

  P requires `0 <= index < sizeof(seq)`; an out-of-range index is a dynamic error (not `nil`, the way
  `Enum.at/2` would yield — it even counts a negative index from the end, which P never means).
  """
  @spec seq_get(machine(), list(), integer()) :: term()
  def seq_get(machine, seq, index) do
    if is_integer(index) and index >= 0 and index < length(seq) do
      Enum.at(seq, index)
    else
      dynamic_error(machine, "sequence index #{inspect(index)} out of range 0..#{length(seq) - 1}")
    end
  end

  @doc """
  Read element `index` of set `set` (P `set[index]`).

  A P set is indexable (in its internal order); P requires `0 <= index < sizeof(set)`. An
  out-of-range index is a dynamic error.
  """
  @spec set_get(machine(), MapSet.t(), integer()) :: term()
  def set_get(machine, set, index) do
    size = MapSet.size(set)

    if is_integer(index) and index >= 0 and index < size do
      Enum.at(MapSet.to_list(set), index)
    else
      dynamic_error(machine, "set index #{inspect(index)} out of range 0..#{size - 1}")
    end
  end

  @doc """
  Look up `key` in map `m` (P `m[key]`).

  P requires the key to be present; a missing key is a dynamic error rather than the `nil` that
  `Map.get/2` would return and let the program continue with.
  """
  @spec map_get(machine(), map(), term()) :: term()
  def map_get(machine, m, key) do
    case Map.fetch(m, key) do
      {:ok, value} -> value
      :error -> dynamic_error(machine, "map key #{inspect(key)} not found")
    end
  end

  @doc """
  Replace element `index` of sequence `seq` with `value` (P `seq[index] = value`).

  P requires `0 <= index < sizeof(seq)`; an out-of-range index is a dynamic error rather than the
  silent no-op `List.replace_at/3` performs.
  """
  @spec seq_set(machine(), list(), integer(), term()) :: list()
  def seq_set(machine, seq, index, value) do
    if is_integer(index) and index >= 0 and index < length(seq) do
      List.replace_at(seq, index, value)
    else
      dynamic_error(machine, "sequence index #{inspect(index)} out of range 0..#{length(seq) - 1}")
    end
  end

  @doc """
  Insert `value` into sequence `seq` at `index` (P `seq += (index, value)`).

  P allows `0 <= index <= sizeof(seq)` (index `sizeof` appends); anything else is a dynamic error
  rather than the clamping `List.insert_at/3` does (a negative index counts from the end, an index
  past the end appends).
  """
  @spec seq_insert(machine(), list(), integer(), term()) :: list()
  def seq_insert(machine, seq, index, value) do
    if is_integer(index) and index >= 0 and index <= length(seq) do
      List.insert_at(seq, index, value)
    else
      dynamic_error(machine, "sequence insert index #{inspect(index)} out of range 0..#{length(seq)}")
    end
  end

  @doc """
  Remove element `index` from sequence `seq` (P `seq -= (index)`).

  P requires `0 <= index < sizeof(seq)`; an out-of-range index is a dynamic error rather than the
  silent no-op `List.delete_at/2` performs.
  """
  @spec seq_remove(machine(), list(), integer()) :: list()
  def seq_remove(machine, seq, index) do
    if is_integer(index) and index >= 0 and index < length(seq) do
      List.delete_at(seq, index)
    else
      dynamic_error(machine, "sequence remove index #{inspect(index)} out of range 0..#{length(seq) - 1}")
    end
  end

  @doc """
  Report a P dynamic error (out-of-range collection index or missing map key) on `machine`.

  Records the error to the trace and logs it at `:error` *before* raising `PRuntime.DynamicError`, so
  it stays visible even where the raise is later swallowed — mirroring `assert/3` and
  `unhandled_event/3`. Never returns.
  """
  @spec dynamic_error(machine(), String.t()) :: no_return()
  def dynamic_error(machine, message) do
    Trace.record({:dynamic_error, machine, message})
    require Logger
    Logger.error("P dynamic error in #{inspect(machine)}: #{message}")
    raise PRuntime.DynamicError, machine: machine, message: message
  end

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

  @doc """
  Build the `:gen_statem` return for `raise event` (a non-halt raise).

  P's `raise E, payload` stops the current handler and processes `E` *ahead of* any further
  queued events, in the current state. Encoded as an `:internal` `:next_event` queued at the
  front, so the raised event is handled before pending casts. The generated `on E` clauses
  match the event content regardless of arrival type, so the same clause services both a sent
  and a raised `E`. `data` is the machine struct as mutated by the handler up to the raise.
  """
  @spec raise_event(machine(), atom(), atom(), term(), term()) :: tuple()
  def raise_event(machine, state, event, payload, data) do
    Trace.record({:raise, machine, state, event})
    {:keep_state, data, [{:next_event, :internal, {:p_event, event, payload}}]}
  end

  @doc """
  Build the `:gen_statem` return for a state that *defers* `event`.

  P's `defer E` holds the event in the queue to be re-delivered after the next state change.
  Maps to `:gen_statem`'s `:postpone` action, which retries the event (in arrival order, at
  the front of the queue) once the state changes — matching P's deferral semantics.
  """
  @spec defer(machine(), atom(), atom()) :: tuple()
  def defer(machine, state, event) do
    Trace.record({:defer, machine, state, event})
    {:keep_state_and_data, [:postpone]}
  end

  @doc """
  Build the `:gen_statem` return for a state that *ignores* `event`.

  P's `ignore E` dequeues the event and discards it with no effect, leaving the state and data
  unchanged.
  """
  @spec ignore(machine(), atom(), atom()) :: :keep_state_and_data
  def ignore(machine, state, event) do
    Trace.record({:ignore, machine, state, event})
    :keep_state_and_data
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

    # Spec monitors are notified at send time, *before* the event is enqueued to the target —
    # matching the C# runtime, where SendEvent announces to monitors first (DESIGN.md Q2).
    PRuntime.Specs.notify(from, name, payload)

    case resolve(target) do
      {:ok, pid} -> :gen_statem.cast(pid, {:p_event, name, payload})
      :halted -> Trace.record({:send_to_halted, from, target, name})
    end

    :ok
  end

  # ---- announce (P `announce E, payload`) ----

  @doc """
  Broadcast `event` (with optional `payload`) to every spec observing it.

  P's `announce` notifies monitors only — it never targets a machine. Like `send_event/4`, fan-out
  is synchronous (see `PRuntime.Specs`): this returns once every observing spec has handled the
  event. Specs that do not observe `event` see nothing.
  """
  @spec announce(machine(), atom(), term()) :: :ok
  def announce(from, event, payload \\ nil) do
    Trace.record({:announce, from, event})
    PRuntime.Specs.notify(from, event, payload)
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
