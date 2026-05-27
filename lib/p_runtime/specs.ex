defmodule PRuntime.Specs do
  @moduledoc """
  Subscription table for P spec monitors and the synchronous fan-out of observed events.

  A P `spec` is a passive monitor: it never sends or creates, it only *observes* a fixed set of
  events and runs assertions over them. On the BEAM each spec is its own `:gen_statem` process
  (reusing the machine codegen), started statically by the generated `<Prefix>.Supervisor` before
  any machine — so by the time a machine sends, every spec has registered what it observes.

  Each spec calls `PRuntime.observes/2` from its `init`, which registers here. This module keeps a
  `%{event => MapSet of spec_id}` table and resolves spec ids to live pids through
  `PRuntime.Registry`. The actual fan-out (`notify/3`) is driven from `PRuntime.send_event/4` and
  `PRuntime.announce/3`.

  ## Synchronous delivery (DESIGN.md Open Question 2)

  The C# reference runtime invokes monitors **synchronously, inline in the caller's stack, at send
  time** — the sender blocks until the monitor has finished handling the event, before the event is
  enqueued to the target. We reproduce that ordering without making the generated spec code reply to
  a call: each observed event is `cast` to the spec, then `:sys.get_state/1` is issued to the spec.
  Because `:gen_statem` drains its mailbox in order and both messages come from the same caller, the
  `:sys.get_state` call cannot return until the cast event has been fully processed — a FIFO flush.
  This keeps spec modules byte-for-byte identical to machine modules (no `{:reply, …}` plumbing)
  while preserving the at-send-time, synchronous observation order.
  """
  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Register that spec `spec_id` observes each event in `events` (idempotent)."
  @spec register(PRuntime.machine(), [atom()]) :: :ok
  def register(spec_id, events) do
    GenServer.call(__MODULE__, {:register, spec_id, events})
  end

  @doc "The ids of all specs observing `event`."
  @spec observers(atom()) :: [PRuntime.machine()]
  def observers(event) do
    GenServer.call(__MODULE__, {:observers, event})
  end

  @doc """
  Synchronously mirror `{:p_event, event, payload}` to every spec observing `event`.

  Delivery to each spec is a `cast` followed by a `:sys.get_state` flush, so this returns only once
  all observing specs have finished handling the event (see the module doc). A spec whose id is no
  longer registered (it halted) is skipped, mirroring the drop-to-halted semantics of sends.

  ## Monitoring is opt-in

  Monitoring is gated by the `:p_runtime, :monitoring` application flag (default `false`). When it
  is off this returns immediately, *before* even looking up observers — so a production deployment
  that runs without specs pays nothing on the send path beyond a single `Application.get_env/3`
  read (an ETS lookup against the application controller's table, lock-free and contention-free).

  Crucially the gate is here, at the *delivery* site, not in the lifecycle: spec processes are
  still started, still register what they observe, and remain inspectable; they simply never get
  fed events while monitoring is off. The two configurations are structurally identical — the only
  difference is whether the fan-out runs. This matches how monitors are opt-in *per test* in P
  itself (`assert Spec in { ... }`): enable them for acceptance/conformance runs where you want the
  faithful synchronous observation, leave them off in production where you want throughput.
  """
  @spec notify(PRuntime.machine(), atom(), term()) :: :ok
  def notify(from, event, payload) do
    if enabled?() do
      deliver(from, event, payload)
    end

    :ok
  end

  @doc "Whether monitoring (spec fan-out) is enabled — the `:p_runtime, :monitoring` flag."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:p_runtime, :monitoring, false)

  defp deliver(_from, event, payload) do
    for spec_id <- observers(event) do
      case Registry.lookup(PRuntime.Registry, spec_id) do
        [{pid, _}] ->
          :gen_statem.cast(pid, {:p_event, event, payload})
          flush(pid)

        [] ->
          :ok
      end
    end
  end

  # FIFO flush: blocks until the cast just sent to `pid` has been handled (see the module doc).
  # A spec that *violates* an assertion raises (and stops) while handling that cast, so the spec
  # may already be dead by the time we flush — `:sys.get_state` then exits. We catch that: the
  # violation is already recorded and logged (PRuntime.assert/3), and a failing monitor must not
  # cascade into and crash the machine that happened to send the observed event.
  defp flush(pid) do
    _ = :sys.get_state(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:register, spec_id, events}, _from, table) do
    table =
      Enum.reduce(events, table, fn event, acc ->
        Map.update(acc, event, MapSet.new([spec_id]), &MapSet.put(&1, spec_id))
      end)

    {:reply, :ok, table}
  end

  @impl true
  def handle_call({:observers, event}, _from, table) do
    {:reply, table |> Map.get(event, MapSet.new()) |> MapSet.to_list(), table}
  end
end
