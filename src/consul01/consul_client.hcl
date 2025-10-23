datacenter = "dc1"

server   = false
data_dir = "/opt/consul/data"

bind_addr   = "0.0.0.0"
client_addr = "0.0.0.0"

# IP интерфейса, попадающего в нашу подсеть 192.168.56.0/24
advertise_addr = "{{ GetPrivateInterfaces | include \"network\" \"192.168.56.0/24\" | attr \"address\" }}"

connect  { enabled = true }
addresses { http = "0.0.0.0" }
ports     { grpc = 8502 }

# IP сервера Consul (consul_server): 192.168.56.20
retry_join = ["192.168.56.20"]

