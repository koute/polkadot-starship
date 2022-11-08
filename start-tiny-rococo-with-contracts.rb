#!/usr/bin/ruby

require_relative "lib.rb"

RELAY_CHAINSPEC = "rococo-local"
PARACHAIN_CHAINSPEC = "contracts-rococo-local"

# Set to true to use the RPC relay node
# (requires a recent version of `polkadot-collator`)
USE_RELAY_RPC_NODE = false

common_extra_args = ["--rpc-cors=all"]
common_env = {
    "RUST_LOG" => "runtime::contracts=debug,sc_cli=info,sc_rpc_server=info,warn"
}

prepare_workspace

relay_chain = create_chain( "relay", POLKADOT, RELAY_CHAINSPEC )

node = create_node( relay_chain, "relay_v001" )
node.is_validator = true
node.is_bootnode = true
node.extra_args = common_extra_args
node.env = common_env

node = create_node( relay_chain, "relay_v002" )
node.is_validator = true
node.extra_args = common_extra_args
node.env = common_env

relay_rpc_node = node

parachain = create_parachain( relay_chain, "para01", POLKADOT_COLLATOR, PARACHAIN_CHAINSPEC )
node = create_node( parachain, "para01_c001" )
node.is_bootnode = true
node.is_collator = true
node.extra_args = common_extra_args
node.env = common_env
node.relay_rpc_node = relay_rpc_node if USE_RELAY_RPC_NODE

node = create_node( parachain, "para01_n001" )
node.relay_rpc_node = relay_rpc_node if USE_RELAY_RPC_NODE
node.extra_args = common_extra_args
node.env = common_env

puts "URLs:"
puts "  polkadot.js: https://polkadot.js.org/apps/?rpc=ws%3A%2F%2F127.0.0.1%3A#{node.ws_port}#/explorer"
puts "  contracts-ui: https://contracts-ui.substrate.io/?rpc=ws%3A%2F%2F127.0.0.1%3A#{node.ws_port}"

start_network relay_chain

# Uncomment to start Grafana + Prometheus:
# start_monitoring
