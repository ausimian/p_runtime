# p_runtime

Runtime support library for [P](https://github.com/p-org/P) programs compiled to
**Elixir / the BEAM** by the P compiler's Elixir backend.

P models communicating state machines that exchange asynchronous, typed events — a shape
the BEAM was built for. The Elixir backend generates one `:gen_statem` per P machine; this
library carries the cross-cutting pieces that do **not** vary with the `.p` source:

- **Registry** — addresses machines by their P name rather than pid.
- **Trace** — an in-memory, ordered recorder of runtime events, used by tests to assert a
  program's observable event trace.
- **Spawner** — serializes `new MachineName(args)` so id allocation is race-free.
- **Specs** — the spec-monitor subscription table and the synchronous fan-out of observed events.
- **Log** — emits each trace entry as a structured, PObserve-friendly `key=value` line.
- **`PRuntime` helpers** — `goto`/`halt`/`raise_event`/`defer`/`ignore` build the `:gen_statem`
  return tuples, `send_event`/`announce` are the (halt-aware, spec-fan-out) delivery wrappers, and
  `created`/`entered`/`dequeued`/`observes` record the trace and register monitors.

Logging is a runtime concern here, never inline in generated code — mirroring how PChecker's
C# runtime logs as a side effect of base-class operations.

## Status

Through M7: machine creation, state entry, `goto`, `raise halt`, payloads/types (including `any`),
cross-machine sends (`new` + registry), defer/ignore, non-halt `raise`, spec monitors with
synchronous `announce`/`send` fan-out plus a PObserve-compatible `key=value` log shape, and faithful
failure surfacing — an unhandled event raises `PRuntime.UnhandledEvent` (rather than being dropped)
and an abnormal process crash is recorded/logged via `terminated/3`. Foreign types/functions (M6)
run entirely in the host's `PForeign` module. A Hex release is deferred; depend on this library via
its GitHub ref for now.

## Usage

Add as a dependency of a generated P/Elixir project (or its host):

```elixir
def deps do
  [{:p_runtime, "~> 0.1"}]
end
```

The library starts its own supervision tree (Registry + Trace + Specs + Spawner) on boot.

## Development

```sh
mix deps.get
mix compile
mix test
```
