defmodule Etcd do
  require Logger
  alias Etcd.Connection
  alias Etcd.Node

  defmodule ServerError do
    defexception [:code,:message,:cause,:index]
  end

  defmodule AsyncReply do
    defstruct id: nil, reply: nil
  end #defmodule AsyncReply

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

  def get!(srv, key, query \\ []) do
    Node.from_map raw_get!(srv, key, query)
  end

  def getAll!(srv, key \\ "/") do
    get!(srv, key, [recursive: true])
  end

  defp raw_get!(srv, key, query) do
    %{"node" => node} = request! srv, :get, key, query, []
    node
  end

  def put!(srv, key, value, body \\ []) do
    body = Dict.put(body, :value, value)
    request! srv, :put, key, [], body
  end

  def delete!(srv, key, body \\ []) do
    request! srv, :delete, key, [], body
  end

  def wait!(srv, key, query \\ [], timeout \\ 10000) do
    query = Dict.put(query, :wait, true)
    request! srv, :get, key, query, [], timeout
  end

  def watch(srv, key, opts) do

  end

  defp request!(srv, verb, key, query \\ [], body \\ [], timeout \\ 5000) do
    case Connection.request(srv, :sync, verb, key, query, body, timeout) do
      {:ok,%{"action" => _action}=reply,_} ->
        reply
      {:ok,%{"errorCode" => errCode, "message" => errMsg, "index" => index}=reply,_} ->
        raise ServerError, code: errCode, message: errMsg, cause: Map.get(reply, "cause", nil), index: index
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
        {:ok, obj, resp} ->
          Logger.debug inspect obj
          node = obj["node"]
          index = node["modifiedIndex"]
          ctx = %{ctx| index: index}
          #:timer.sleep(1000)
          ctx = init_request(ctx)
          send ctx.notify, {:watcher_notify, obj}
          {:noreply, ctx}
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
      id = Etcd.Connection.request(ctx.conn, :async, :get, ctx.key, opts, [])
      %{ctx| id: id, opts: opts}
    end
  end
end

defmodule Etcd.Connection do
  use GenServer
  require Logger
  alias Etcd.AsyncReply

  defstruct schema: "http", hosts: ["127.0.0.1:4001"], prefix: "/v2/keys", ssl_options: []

  defmodule Request do
    defstruct mode: :sync, method: :get, path: nil, query: nil, body: nil, headers: [], opts: [], id: nil, from: nil, stream_to: nil
  end #defmodule Request

  def request(conn, mode, method, path, query, body, timeout \\ 5000) do
    GenServer.call conn, %Request{mode: mode, method: method, path: path, query: query, body: body}, timeout
  end

  def request(conn, %Request{}=req, timeout \\ 5000) do
    GenServer.call conn, req, timeout
  end

  def start_link(uri) do
    GenServer.start_link __MODULE__,uri
  end

  def init(srv) do
    table = :ets.new :requests, [:set, :private]
    {:ok, %{:server => srv, :table => table}}
  end

  def handle_call(req, from, ctx) do
    reply = mkreq ctx, req, from
    if req.mode == :async do
      {:reply, reply, ctx}
    else
      {:noreply,ctx}
    end
  rescue
    err ->
      Logger.error "#{Exception.message err}\n#{Exception.format_stacktrace System.stacktrace}"
      {:reply,{:error,err},ctx}
  end

  def handle_info({:hackney_response, id, {:status, code, reason}}, ctx) do
    update_resp(ctx, id, :status_code, code)
    {:noreply,ctx}
  end
  def handle_info({:hackney_response, id, {:headers, hdr}}, ctx) do
    update_resp(ctx, id, :headers, hdr)
    {:noreply,ctx}
  end
  def handle_info({:hackney_response, id, chunk}, ctx) when is_binary(chunk) do
    update_resp(ctx, id, :body, chunk, fn(parts)-> parts <> chunk end)
    {:noreply,ctx}
  end
  def handle_info({:hackney_response, id, :done}, ctx) do
    finish_resp ctx, id, &(process_response(ctx, &1, &2))
    {:noreply,ctx}
  end
  def handle_info({:hackney_response, id, {:redirect, to, _hdrs}}, ctx) do
    Logger.debug "Redirecting #{inspect id} to #{to}"
    {:noreply,ctx}
  end
  def handle_info({:hackney_response, id, {:error, reason}}, ctx) do
    finish_resp ctx, id, fn(req, resp) ->
      reply req, {:error, reason}
    end
    {:noreply,ctx}
  end

  defp reply(req, reply) do
    case req.mode do
      :async ->
        pid = if req.stream_to do
          req.stream_to
        else
          elem req.from, 0
        end
        send pid, %AsyncReply{id: req.id, reply: reply}
      :sync ->
        GenServer.reply req.from, reply
    end
  end

  defp finish_resp(ctx, id, cb) do
    case :ets.lookup(ctx.table,id) do
      [{^id, req, resp}]->
        :ets.delete ctx.table,id
        cb.(req,resp)
      _ ->
        Logger.warn "Not found: #{inspect id}"
        :error
    end
  end

  defp update_resp(ctx, id, field, value, fun \\ nil) do
    unless fun do
      fun = fn(_any) -> value end
    end
    case :ets.lookup(ctx.table,id) do
      [{^id, from, resp}]->
        resp = Dict.update(resp, field, value, fun)
        :ets.insert ctx.table, {id, from, resp}
      _ ->
        Logger.warn "Not found: #{inspect id}"
        :error
    end
  end

  defp mkurl(ctx, req) do
    uri = ctx.server
    ret = uri.schema <> "://" <> hd(uri.hosts) <> uri.prefix <> req.path
    if req.query do
      ret <> "?" <> URI.encode_query req.query
    else
      ret
    end
  end

  defp mkhdrs(ctx, req) do
    if req.body do
      Enum.into req.headers,[{"Content-Type","application/x-www-form-urlencoded"}]
    else
      req.headers
    end
  end

  defp mkbody(ctx, req) do
    if req.body do
      URI.encode_query req.body
    else
      ""
    end
  end

  defp mkopts(ctx, opts) do
    uri = ctx.server
    opts
    |> Dict.put(:ssl_options, uri.ssl_options)
    |> Dict.put(:stream_to, self())
    |> Dict.put(:follow_redirect, true)
    |> Dict.put(:force_redirect, true)
    |> Dict.put(:async, :true)
  end


  defp mkreq(ctx, req, from) do
    method  = req.method
    url     = mkurl  ctx, req
    headers = mkhdrs ctx, req
    body    = mkbody ctx, req
    options = mkopts ctx, req.opts

    Logger.debug "#{method} #{url} #{inspect headers} #{inspect body} #{inspect options}"
    case :hackney.request(method, url, headers, body, options) do
      {:ok, id} ->
        req = %{req| from: from, id: id}
        :ets.insert ctx.table, {id, req, %{body: ""}}
        {:ok, id}
      {:error, e} ->
        raise e
    end
  end

  defp process_response(ctx, req, resp) do
    IO.inspect resp
    Logger.debug "get #{resp.status_code}"
    body = JSX.decode! resp.body
    reply req, {:ok, body, resp}
  rescue err ->
    Logger.error "Bad response: #{inspect resp}\n#{Exception.message err}\n#{Exception.format_stacktrace System.stacktrace}"
    reply req, {:error, err}
  end
end

defmodule Etcd.URI do
  require Logger
end

