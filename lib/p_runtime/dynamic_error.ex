defmodule PRuntime.DynamicError do
  @moduledoc """
  Raised when a P program hits a dynamic (runtime) error on a collection operation.

  P defines runtime error cases for collection access: indexing a `seq`/`set` outside
  `0 <= i < sizeof`, inserting into a `seq` outside `0 <= i <= sizeof`, removing/replacing a
  `seq` element outside `0 <= i < sizeof`, and looking up a `map` key that is not present. In the
  C# runtime these surface as the underlying collection throwing (e.g. a missing-key lookup or an
  out-of-range index aborts the machine). The Elixir backend mirrors that: generated code routes
  every such access through a `PRuntime` collection helper, which raises this exception instead of
  the permissive Elixir default (`Map.get` returning `nil`, `Enum.at` returning `nil`,
  `List.insert_at`/`List.replace_at`/`List.delete_at` clamping) that would let the program limp on
  with a wrong value and mask the divergence from the P semantics.

  It is a distinct exception type — like `PRuntime.SafetyViolation` (failed `assert`) and
  `PRuntime.UnhandledEvent` — so a host or test harness can tell a genuine P dynamic error apart
  from an incidental crash (`rescue PRuntime.DynamicError`, or matching the process exit reason).
  Carries the offending machine id and a message describing the out-of-range index or missing key.
  The error is recorded to the trace and logged before this is raised — see `PRuntime.dynamic_error/2`.
  """
  defexception [:machine, :message]

  @impl true
  def message(%__MODULE__{machine: machine, message: message}) do
    "P dynamic error in #{inspect(machine)}: #{message}"
  end
end
