ElixirEtcd
==========

```

require Logger

server = %Etcd.Connection{
  hosts: ["127.0.0.1:4001"],
  ssl_options: [
    {:certfile, 'etcd_client.crt'},
    {:keyfile, 'etcd_client.key'},
  ]
}

{:ok,conn} = Etcd.Connection.start_link server
#IO.inspect Etcd.Connection.request(server,:get,"/test/foobar/xx/yy")
IO.inspect Etcd.get? conn,"/test"
IO.inspect Etcd.put! conn,"/test","hello world"
IO.inspect Etcd.put! conn,"/test","hello", [prevValue: "hello world"]
IO.inspect Etcd.delete! conn,"/test"
IO.inspect Etcd.put! conn,"/test","hello world", ttl: 10
IO.inspect Etcd.put! conn,"/foo/bar/test","hello world", ttl: 3
for x <- Etcd.ls!(conn,"/", true, true, true) ,do: IO.inspect x.key
IO.inspect Etcd.wait! conn,"/",recursive: true

```
