defmodule PRuntime.Trace do
  @moduledoc """
  In-memory, ordered recorder of runtime events for a running P program.

  This is the M1 stand-in for the structured logger described in the design doc: the
  *format* of trace entries is owned here, in the runtime, never in generated code.
  Tests reset the trace, run a program, and assert on `entries/0`.

  Entries are tagged tuples (see `PRuntime`), e.g. `{:enter, "Walker", :B}`.
  """
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc "Append an entry to the trace."
  @spec record(term()) :: :ok
  def record(entry) do
    Agent.update(__MODULE__, fn entries -> [entry | entries] end)
  end

  @doc "All recorded entries, in chronological order."
  @spec entries() :: [term()]
  def entries do
    Agent.get(__MODULE__, &Enum.reverse/1)
  end

  @doc "Clear the trace. Call at the start of a test, before starting any machines."
  @spec reset() :: :ok
  def reset do
    Agent.update(__MODULE__, fn _ -> [] end)
  end
end
