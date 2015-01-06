defmodule Etcd do
  require Logger
  alias Etcd.Connection
  alias Etcd.Node

  defmodule ServerError do
    defexception [:code,:message]
  end

  def dir(srv, root,recursive \\ false) do
    ls!(srv, false, true, recursive)
  end
  def keys(srv, root, recursive \\ false) do
    ls!(srv, true, false, recursive)
  end
  def ls!(srv, root, allow_leaf \\ true, allow_node \\ true, recursive \\ false) do
    case get! srv, root, [recursive: recursive] do
      %Node{dir: true, nodes: nodes} ->
        Enum.flat_map(nodes, &flat_node/1) |> Enum.filter(fn
          (%Node{dir: true}) -> allow_node
          (%Node{dir: false}) -> allow_leaf
        end)
      node->
        [node]
    end
  end

  defp flat_node(%Node{dir: false}=leaf), do: [leaf]
  defp flat_node(%Node{dir: true }=node), do: [node|Enum.flat_map(node.nodes, &flat_node/1)]

  def get?(srv, key, opts \\ []) do
    try do
      get! srv, key, opts
    rescue
      ServerError -> nil
    end
  end

  def get!(srv, key, opts \\ []) do
    Node.from_map raw_get!(srv, key, opts)
  end

  def getAll!(srv, key \\ "/") do
    get!(srv, key, [recursive: true])
  end

  defp raw_get!(srv, key, opts) do
    %{"node" => node} = request! srv, :get, key, opts
    node
  end

  def put!(srv, key, value, opts \\ []) do
    opts = Dict.put(opts, :value, value)
    request! srv, :put, key, opts
  end

  def delete!(srv, key, opts \\ []) do
    request! srv, :delete, key, opts
  end

  def wait!(srv, key, opts \\ [], timeout \\ 10000) do
    opts = Dict.put(opts, :wait, true)
    request! srv, :get, key, opts, timeout
  end

  def watch(srv, key, opts) do

  end

  defp request!(srv, verb, key, opts, timeout \\ 5000) do
    case Connection.request(srv, verb, key, opts, timeout) do
      {:ok,%{"action" => _action}=reply} ->
        reply
      {:ok,%{"errorCode" => errCode, "message" => errMsg}} ->
        raise ServerError, code: errCode, message: errMsg
      {:error,e} ->
        raise e
    end
  end

  defmodule Watcher do
    use GenServer
    def start_link(conn, key, opts \\ []) do
      GenServer.start_link __MODULE__, %{conn: conn, key: key, opts: opts}
    end
    def init(ctx) do
      {:ok, ctx}
    end
    def handle_call(:stop,_,ctx) do
      {:stop,:normal,:ok,ctx}
    end
  end
end

defmodule Etcd.Connection do
  use GenServer
  require Logger
  alias Etcd.Server
  alias HTTPoison.AsyncResponse
  alias HTTPoison.AsyncStatus
  alias HTTPoison.AsyncHeaders
  alias HTTPoison.AsyncChunk
  alias HTTPoison.AsyncEnd
  alias HTTPoison.Response
  alias HTTPoison.Error

  def request(conn, method, path, opts, timeout \\ 5000) do
    GenServer.call conn, {method, path, opts}, timeout
  end

  def request_async(conn, method, path, opts) do
    id = make_ref
    :ok = GenServer.cast conn, {id, self, method, path, opts}
    id
  end

  def start_link(srv) do
    GenServer.start_link __MODULE__,srv
  end

  def init(srv) do
    table = :ets.new :requests, [:set, :private]
    {:ok, %{:server => srv, :table => table}}
  end

  def handle_call({method,path,payload}, from, ctx) do
    try do
      req = make_request ctx.server, method, path, payload, from
      send_request! ctx, req
      {:noreply,ctx}
    rescue
      e -> {:reply,{:error,e},ctx}
    end
  end

  def handle_cast({id, pid, method, path, payload}, ctx) do
    try do
      from = {:async, id, pid}
      req = make_request ctx.server, method, path, payload, from
      send_request! ctx, req
    rescue
      e -> reply from,{:error,e}
    end
    {:noreply, ctx}
  end

  def handle_info(%AsyncStatus{id: id, code: code}, ctx) do
    update_resp(ctx.table, id, :status_code, code)
    {:noreply,ctx}
  end
  def handle_info(%AsyncHeaders{id: id, headers: hdr}, ctx) do
    update_resp(ctx.table, id, :headers, hdr)
    {:noreply,ctx}
  end
  def handle_info(%AsyncChunk{id: id, chunk: chunk}, ctx) do
    update_resp(ctx.table, id, :body, chunk, fn(parts)-> parts <> chunk end)
    {:noreply,ctx}
  end
  def handle_info(%AsyncEnd{id: id}, ctx) do
    finish_resp ctx.table, id, &(process_response(ctx.server, &1, &2))
    {:noreply,ctx}
  end
  def handle_info(%Error{id: id, reason: reason}, ctx) do
    finish_resp ctx.table, id, fn(req, resp) ->
      reply req.from, {:error, reason}
    end
    {:noreply,ctx}
  end

  defp reply({:async, id, from}, reply) do
    send from, %Etcd.AsyncReply{:id: id, :reply: reply}
  end

  defp reply(from, reply) do
    GenServer.reply from, reply
  end

  defp finish_resp(table, id, cb) do
    case :ets.lookup(table,id) do
      [{^id, req, resp}]->
        :ets.delete table,id
        cb.(req,resp)
      _ ->
        :error
    end
  end

  defp update_resp(table, id, field, value, fun \\ nil) do
    unless fun do
      fun = fn(_any) -> value end
    end
    case :ets.lookup(table,id) do
      [{^id, from, resp}]->
        resp = Dict.update(resp, field, value, fun)
        :ets.insert table, {id, from, resp}
      _ ->
        :error
    end
  end

  def make_request(server, method, path, payload, from) do
    url = Server.mkurl server, path
    query = URI.encode_query payload
    header = [{"Content-Type","application/x-www-form-urlencoded"}]
    if method == :get do
      if query != "" do
        url = url <> "?" <> query
      end
      query = []
      header = []
    end
    Logger.debug "#{method} #{url} #{query}"
    %{
      method: method,
      url: url,
      header: header,
      query: query,
      options: Server.mkopts(server)++[stream_to: self],
      from: from,
    }
  end

  defp send_request!(ctx, req) do
    %AsyncResponse{id: id} = HTTPoison.request!(
      req.method, req.url, req.query, req.header, req.options
    )
    :ets.insert ctx.table, {id, req, %{}}
  end

  defp process_response(ctx, req, resp) do
    case resp do
      %{status_code: 307, headers: hdr } ->
        next = Map.get hdr, "Location"
        if next do
          Logger.debug "got 307, goto #{next}"
          req = Dict.put req, :url, next
          send_request! ctx, req
        else
          Logger.warn "Redirection without location header!"
          reply req.from, {:error, :badarg}
        end

      %{status_code: code, body: resp} ->
        Logger.debug "get #{code}"
        try do
          reply req.from, {:ok, JSX.decode!(resp)}
        rescue
          ArgumentError ->
            Logger.error "Bad response [#{code}]: #{resp}"
            reply req.from, {:error,:badarg}
        end
    end
  end
end

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


