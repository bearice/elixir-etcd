defmodule ElixirEtcd.Mixfile do
  use Mix.Project

  def project do
    [app: :etcd,
     version: "0.0.1",
     elixir: "~> 1.0",
     description: desc,
     package: package,
     deps: deps]
  end

  def application do
    [
      applications: [
        :logger,
        :exjsx,
        :httpoison,
      ],
      env: [
        url: "http://127.0.0.1:4001",
        crt: "./etcd.crt",
        key: "./etcd.key",
        ca:  "./ca.crt",
      ]
    ]
  end

  defp deps do
    [
      {:exjsx, "~> 3.0"},
      {:httpoison, "~> 0.5.0"},
    ]
  end

  defp desc do
    """
    Etcd APIv2 Client for Elixir
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      contributors: ["Bearice Ren"],
      links: %{"Github" => "https://github.com/bearice/elixir-etcd"}
    ]
  end
end
