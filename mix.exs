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

  # Configuration for the OTP application
  #
  # Type `mix help compile.app` for more information
  def application do
    [
      applications: [
        :logger,
        :exjsx,
        :httpoison,
      ],
      mod: {Etcd.Application,[]},
      env: [
        url: "http://127.0.0.1:4001",
        crt: "./etcd.crt",
        key: "./etcd.key",
        ca:  "./ca.crt",
      ]
    ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type `mix help deps` for more examples and options
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
