defmodule PRuntime.Log do
  @moduledoc """
  Structured, PObserve-friendly log emission for a running P program.

  Every trace entry recorded by `PRuntime.Trace` is also emitted here as a single `key=value` line
  via `Logger`. Logging lives entirely in the runtime, never in generated code (DESIGN.md): the
  generated modules call `PRuntime` helpers, those helpers funnel through `PRuntime.Trace.record/1`,
  and this module turns each entry into a line.

  ## Format

  Each line is space-separated `key=value` pairs, always starting with `type=`. For example:

      type=send from=Main to=Server event=eReq
      type=enter machine=Watcher state=Watching
      type=announce from=Server event=eObserved

  There is no cross-backend log standard to match (DESIGN.md Open Question 4): PObserve consumes an
  application's logs through a user-written `Parser`, so this shape is ours to define. A PObserve
  `Parser` for P-on-Elixir maps these `key=value` lines to `PObserveEvent`s; the keys above are the
  contract it parses.

  Lines are emitted at `:debug` so they are silent under the default `Logger` level and a host that
  wants them (e.g. to feed PObserve) simply lowers the level.
  """
  require Logger

  @doc "Emit a structured log line for a trace entry."
  @spec emit(tuple()) :: :ok
  def emit(entry) do
    Logger.debug(fn -> format(entry) end)
    :ok
  end

  defp format({:create, machine}), do: kv(type: :create, machine: machine)
  defp format({:enter, machine, state}), do: kv(type: :enter, machine: machine, state: state)

  defp format({:dequeue, machine, state, event}),
    do: kv(type: :dequeue, machine: machine, state: state, event: event)

  defp format({:goto, machine, from, to}),
    do: kv(type: :goto, machine: machine, from: from, to: to)

  defp format({:halt, machine, state}), do: kv(type: :halt, machine: machine, state: state)

  defp format({:raise, machine, state, event}),
    do: kv(type: :raise, machine: machine, state: state, event: event)

  defp format({:defer, machine, state, event}),
    do: kv(type: :defer, machine: machine, state: state, event: event)

  defp format({:ignore, machine, state, event}),
    do: kv(type: :ignore, machine: machine, state: state, event: event)

  defp format({:send, from, to, event}), do: kv(type: :send, from: from, to: to, event: event)

  defp format({:send_to_halted, from, to, event}),
    do: kv(type: :send_to_halted, from: from, to: to, event: event)

  defp format({:announce, from, event}), do: kv(type: :announce, from: from, event: event)

  defp format(other), do: kv(type: :unknown, data: inspect(other))

  defp kv(pairs), do: Enum.map_join(pairs, " ", fn {k, v} -> "#{k}=#{value(v)}" end)

  defp value(v) when is_atom(v), do: Atom.to_string(v)
  defp value(v) when is_binary(v), do: v
  defp value(v), do: inspect(v)
end
