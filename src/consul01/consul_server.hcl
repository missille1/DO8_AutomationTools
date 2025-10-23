# consul_server.hcl
datacenter     = "dc1"
node_name      = "consul_server"
data_dir       = "/opt/consul/data"

bind_addr      = "192.168.56.20"
advertise_addr = "192.168.56.20"

server           = true
bootstrap_expect = 1

client_addr = "0.0.0.0"
ui_config { enabled = true }

connect { enabled = true }

# Явно открываем gRPC-порт для Envoy/xDS
ports { grpc = 8502 }

