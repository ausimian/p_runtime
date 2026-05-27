# p_runtime

Runtime support library for [P](https://github.com/p-org/P) programs compiled to
**Elixir / the BEAM** by the P compiler's Elixir backend.

P models communicating state machines that exchange asynchronous, typed events — a shape
the BEAM was built for. The Elixir backend generates one `:gen_statem` per P machine; this
library carries the cross-cutting pieces that do **not** vary with the `.p` source:

- **Registry** — addresses machines by their P name rather than pid.
- **Trace** — an in-memory, ordered recorder of runtime events, used by tests to assert a
  program's observable event trace.
- **`PRuntime` helpers** — `goto`/`halt` build the `:gen_statem` return tuples, `send_event`
  is the (halt-aware) async send wrapper, and `created`/`entered`/`dequeued` record the trace.

Logging is a runtime concern here, never inline in generated code — mirroring how PChecker's
C# runtime logs as a side effect of base-class operations.

## Status

Early (M1, the "walking skeleton"): machine creation, state entry, `goto`, `raise halt`, and
a `send` wrapper. Payloads/types, cross-machine sends, defer/ignore, and specs/announce arrive
in later milestones, along with a PObserve-compatible log shape.

## Usage

Add as a dependency of a generated P/Elixir project (or its host):

```elixir
def deps do
  [{:p_runtime, "~> 0.1"}]
end
```

The library starts its own supervision tree (Registry + Trace) on boot.

## Development

```sh
mix deps.get
mix compile
mix test
```
