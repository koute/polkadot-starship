#!/usr/bin/ruby

require_relative "lib.rb"

RELAY_CHAINSPEC = "rococo-local"
PARACHAIN_CHAINSPEC = ""

relay_chain = create_chain( "relay", POLKADOT, RELAY_CHAINSPEC )

node = create_node( relay_chain, "relay_v001" )
node.is_validator = true
node.is_bootnode = true

node = create_node( relay_chain, "relay_v002" )
node.is_validator = true

node = create_node( relay_chain, "relay_n001" )

parachain = create_parachain( relay_chain, "para01", POLKADOT_COLLATOR, PARACHAIN_CHAINSPEC )
node = create_node( parachain, "para01_c001" )
node.is_bootnode = true
node.is_collator = true
node.extra_args += ["--force-authoring"]

start_network relay_chain
start_monitoring
