#!/usr/bin/ruby

require_relative "lib.rb"

RELAY_CHAINSPEC = "rococo-local"
PARACHAIN_CHAINSPEC = ""

relay_chain = create_chain( "relay", POLKADOT, RELAY_CHAINSPEC )

# Relay chain
node = create_node( relay_chain, "relay_v001" )
node.is_validator = true
node.is_bootnode = true

node = create_node( relay_chain, "relay_v002" )
node.is_validator = true

node = create_node( relay_chain, "relay_v003" )
node.is_validator = true

node = create_node( relay_chain, "relay_n001" )

# Parachain #1
parachain_1 = create_parachain( relay_chain, "para01", POLKADOT_COLLATOR, PARACHAIN_CHAINSPEC )
node = create_node( parachain_1, "para01_c001" )
node.is_bootnode = true
node.is_collator = true

node = create_node( parachain_1, "para01_c002" )
node.is_collator = true

node = create_node( parachain_1, "para01_n001" )

# Parachain #2
parachain_2 = create_parachain( relay_chain, "para02", POLKADOT_COLLATOR, PARACHAIN_CHAINSPEC )
node = create_node( parachain_2, "para02_c001" )
node.is_bootnode = true
node.is_collator = true

node = create_node( parachain_2, "para02_c002" )
node.is_collator = true

node = create_node( parachain_2, "para02_n001" )

connect_with_hrmp( parachain_1, parachain_2 )
connect_with_hrmp( parachain_2, parachain_1 )


start_network relay_chain
