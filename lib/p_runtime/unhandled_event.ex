defmodule PRuntime.UnhandledEvent do
  @moduledoc """
  Raised when a P machine receives an event its current state neither handles, defers, nor ignores.

  P treats this as an error: a machine that dequeues an event with no matching action in the
  current state aborts. The Elixir backend mirrors that — the generated `handle_event/4` catch-all
  routes such an event through `PRuntime.unhandled_event/3`, which records it to the trace, logs it
  at `:error`, and raises this exception (rather than silently dropping the event, which would mask
  a real divergence from the P semantics).

  It is a distinct exception type so a host or test harness can tell it apart from an incidental
  crash (`rescue PRuntime.UnhandledEvent`, or matching the process exit reason), the same way
  `PRuntime.SafetyViolation` distinguishes a failed `assert`. Stray non-P messages (`:info` and the
  like) are *not* funnelled here — the generated catch-all ignores those, so this only ever fires
  for a genuine unhandled P event.
  """
  defexception [:machine, :state, :event]

  @impl true
  def message(%__MODULE__{machine: machine, state: state, event: event}) do
    "P machine #{inspect(machine)} received event #{inspect(event)} unhandled in state #{inspect(state)}"
  end
end
