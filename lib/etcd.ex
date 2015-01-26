defmodule Etcd do
  require Logger
  alias Etcd.Connection
  alias Etcd.Node

  defmodule ServerError do
    defexception [:code,:message]
  end

  defmodule AsyncReply do
    defstruct id: nil, reply: nil
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
    def start_link(conn, key, opts) do
      GenServer.start_link __MODULE__, %{conn: conn, key: key, opts: opts, id: nil, index: nil, notify: self}
    end
    def stop(pid) do
      GenServer.call pid, :stop
    end
    def init(ctx) do
      ctx = init_request(ctx)
      {:ok, ctx}
    end
    def handle_call(:stop,_,ctx) do
      {:stop,:normal,:ok,ctx}
    end
    def handle_info(%Etcd.AsyncReply{id: id, reply: reply},ctx) do
      case reply do
        {:ok, obj} ->
          Logger.debug inspect obj
          node = obj["node"]
          index = node["modifiedIndex"]
          ctx = %{ctx| index: index}
          #:timer.sleep(1000)
          ctx = init_request(ctx)
          send ctx.notify, {:watcher_notify, obj}
          {:noreply, ctx}
        {:empty, %{headers: hdr}} ->
          Logger.debug "Empty response, retry..."
          index = String.to_integer hdr["X-Etcd-Index"]
          ctx = %{ctx| index: index}
          ctx = init_request(ctx)
        {:error,{:closed, _}} ->
          Logger.debug "Connection closed, retry..."
          ctx = init_request(ctx)
          {:noreply, ctx}
        {:error, err} ->
          Logger.warn "Watcher error: #{inspect err}"
          send ctx.notify, {:watcher_error, err}
          {:stop,err}
      end
    end
    defp init_request(ctx) do
      opts = Dict.put ctx.opts, :wait, true
      if ctx.index do
        opts = Dict.put ctx.opts, :waitIndex, ctx.index+1
      end
      id = Etcd.Connection.request_async(ctx.conn, :get, ctx.key, opts)
      %{ctx| id: id, opts: opts}
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
    from = {:async, id, pid}
    try do
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
    send from, %Etcd.AsyncReply{id: id, reply: reply}
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
        Logger.warn "Not found: #{inspect id}"
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
        Logger.warn "Not found: #{inspect id}"
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
    :ets.insert ctx.table, {id, req, %{body: ""}}
  end

  defp process_response(ctx, req, resp) do
    IO.inspect resp
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

      %{status_code: 200,  body: ""} ->
        reply req.from, {:empty, resp}
      %{status_code: code, body: body} ->
        Logger.debug "get #{code}"
        try do
          reply req.from, {:ok, JSX.decode!(body)}
        rescue
          ArgumentError ->
            Logger.error "Bad response [#{code}]: #{inspect resp}"
            reply req.from, {:error,:badarg}
        end
    end
  end
end
