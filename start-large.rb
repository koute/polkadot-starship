#!/usr/bin/ruby

require_relative "lib.rb"

RELAY_CHAINSPEC = "rococo-local"
RELAY_VALIDATORS = 10
RELAY_NON_VALIDATORS = 20

PARACHAIN_CHAINSPECS = ["", "", "statemint-local"]
PARACHAIN_COLLATORS = 2
PARACHAIN_NON_COLLATORS = 5

COMMON_EXTRA_ARGS = [
    # This cuts down on the memory usage significantly.
    "--wasm-execution",
    "interpreted-i-know-what-i-do"
]

relay_chain = create_chain( "relay", POLKADOT, RELAY_CHAINSPEC )
node = create_node( relay_chain, "relay_bootnode" )
node.is_bootnode = true
node.extra_args += COMMON_EXTRA_ARGS

RELAY_VALIDATORS.times do |n|
    node = create_node( relay_chain, "relay_v%03i" % [n + 1] )
    node.is_validator = true
    node.extra_args += COMMON_EXTRA_ARGS
end

RELAY_NON_VALIDATORS.times do |n|
    node = create_node( relay_chain, "relay_n%03i" % [n + 1] )
    node.extra_args += COMMON_EXTRA_ARGS
end

parachains = []
PARACHAIN_CHAINSPECS.each_with_index.each do |chainspec_name, p|
    parachain = create_parachain( relay_chain, "para%02i" % [p + 1], POLKADOT_COLLATOR, chainspec_name )
    parachains << parachain

    node = create_node( parachain, "para%02i_bootnode" % [p + 1] )
    node.is_bootnode = true
    node.extra_args += COMMON_EXTRA_ARGS
    node.relaynode.extra_args += COMMON_EXTRA_ARGS

    PARACHAIN_COLLATORS.times do |n|
        node = create_node( parachain, "para%02i_c%03i" % [p + 1, n + 1] )
        node.is_collator = true
        node.extra_args += COMMON_EXTRA_ARGS
        node.relaynode.extra_args += COMMON_EXTRA_ARGS
    end

    PARACHAIN_NON_COLLATORS.times do |n|
        node = create_node( parachain, "para%02i_n%03i" % [p + 1, n + 1] )
        node.extra_args += COMMON_EXTRA_ARGS
        node.relaynode.extra_args += COMMON_EXTRA_ARGS
    end
end

connect_with_hrmp( parachains[0], parachains[1] )
connect_with_hrmp( parachains[1], parachains[0] )
connect_with_hrmp( parachains[1], parachains[2] )
connect_with_hrmp( parachains[2], parachains[1] )

start_network relay_chain
start_monitoring
