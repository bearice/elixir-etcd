defmodule Etcd.Node do
  @derive [Access,Collectable]
  defstruct [
    dir: false,
    key: nil,
    nodes: nil,
    createdIndex: nil,
    modifiedIndex: nil,
    ttl: nil,
    expiration: nil,
  ]

  def from_map(map) do
      load_nodes(Enum.into(map, %Etcd.Node{}, fn({k,v})->{String.to_existing_atom(k),v} end))
  end

  defp load_nodes(%{dir: false} = node), do: node
  defp load_nodes(%{dir: true} = node), do: %{node | nodes: load_nodes(node.nodes) }
  defp load_nodes(nil), do: nil
  defp load_nodes(lst) when is_list(lst), do: Enum.map(lst, &from_map/1)
end

defmodule Etcd.Server do
  require Logger
  defstruct url: "http://127.0.0.1:4001", ssl_options: [] 


  defp fetch_response(server, method, url, query, header, opts) do
    ret = HTTPoison.request method, url, query, header, opts
    #IO.inspect ret
    case ret do
      {:error,err} ->
        Logger.error "request error: #{err.message}"
        {:error,err}
      {:ok, resp} ->
        process_response server, resp 
    end
  end

  def mkurl(server, path) do
    server.url <> "/v2/keys" <> path
  end

  def mkopts(server) do
    [
      hackney: [
        ssl_options: server.ssl_options,
      ],
    ]
  end
end


