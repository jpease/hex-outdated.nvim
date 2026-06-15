defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo,
      version: "0.1.0",
      elixir: "~> 1.16",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:ecto, "== 3.0.0"},
      {:telemetry, "~> 1.2"},
      {:does_not_exist_xyz, "~> 2.0"}
    ]
  end
end
