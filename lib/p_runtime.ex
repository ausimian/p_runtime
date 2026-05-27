defmodule PRuntime do
  @moduledoc """
  Runtime support for P programs compiled to Elixir (the `p_runtime` library).

  Owns the cross-cutting pieces that do *not* vary with the `.p` source: the registry,
  structured logging/tracing, the send wrapper (with halt-aware semantics), and helpers
  that build `:gen_statem` return tuples while recording the corresponding trace entry.

  This mirrors how PChecker works: generated machine modules call these helpers, and
  logging happens here as a side effect — never inline in generated code. See DESIGN.md.

  ## M1 scope

  Only the pieces the M1 walking skeleton needs: machine creation, state entry, dequeue,
  `goto`, `raise halt`, and a `send`/cast wrapper. Payloads, specs/announce, and the full
  PObserve log shape arrive in later milestones.
  """

  alias PRuntime.Trace

  @typedoc "A P machine's identity in the trace (its P name)."
  @type machine :: String.t()

  # ---- lifecycle / logging (side-effecting calls from generated code) ----

  @doc "Record that `machine` was created."
  @spec created(machine()) :: :ok
  def created(machine), do: Trace.record({:create, machine})

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
  """
  @spec goto(machine(), atom(), atom(), term(), term()) :: tuple()
  def goto(machine, from, target, data, payload \\ nil) do
    Trace.record({:goto, machine, from, target})
    {:next_state, target, data, [{:next_event, :internal, {:__entry__, payload}}]}
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

  Async cast, matching P's non-blocking `send`. If the target process is dead (halted),
  the cast is dropped and a `:send_to_halted` entry is logged instead — mirroring the
  C# runtime, where enqueue to a halted machine returns `Dropped`.
  """
  @spec send_event(machine(), :gen_statem.server_ref(), atom(), term()) :: :ok
  def send_event(from, target, name, payload \\ nil) do
    Trace.record({:send, from, target, name})

    if alive?(target) do
      :gen_statem.cast(target, {:p_event, name, payload})
    else
      Trace.record({:send_to_halted, from, target, name})
    end

    :ok
  end

  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(_other), do: true
end
