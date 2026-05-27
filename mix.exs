defmodule PRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :p_runtime,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Starts the runtime's own supervision tree (Registry + Trace) when the app boots,
  # so generated programs can rely on them being available.
  def application do
    [
      extra_applications: [:logger],
      mod: {PRuntime.Application, []}
    ]
  end

  defp deps do
    []
  end
end
