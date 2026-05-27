defmodule PRuntime.SafetyViolation do
  @moduledoc """
  Raised when a P `assert` fails at runtime.

  P `assert` expresses a *safety* property ("nothing bad happens"), so a failed assertion is a
  genuine violation, not a recoverable error. It is a distinct exception type — rather than a bare
  `raise "message"` — so a host or test harness can pattern-match on it (`rescue PRuntime.SafetyViolation`
  or matching the process exit reason) and tell a real safety violation apart from an incidental crash.

  Carries the violating machine/spec id and the assertion message (already prefixed with the source
  location by the compiler). The violation is recorded to the trace and logged before this is raised
  — see `PRuntime.assert/3`.
  """
  defexception [:machine, :message]

  @impl true
  def message(%__MODULE__{machine: machine, message: message}) do
    "P safety violation in #{inspect(machine)}: #{message}"
  end
end
