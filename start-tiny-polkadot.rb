#!/usr/bin/ruby

require_relative "lib.rb"

RELAY_CHAINSPEC = "polkadot-local"

prepare_workspace

relay_chain = create_chain( "relay", POLKADOT, RELAY_CHAINSPEC )

node = create_node( relay_chain, "relay_v001" )
node.is_validator = true
node.is_bootnode = true

node = create_node( relay_chain, "relay_v002" )
node.is_validator = true

node = create_node( relay_chain, "relay_n001" )

start_network relay_chain
start_monitoring
