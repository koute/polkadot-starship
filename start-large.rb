#!/usr/bin/ruby

require_relative "lib.rb"

RELAY_CHAINSPEC = "rococo-local"
RELAY_VALIDATORS = 10
RELAY_NON_VALIDATORS = 20

PARACHAIN_CHAINSPECS = ["", "", "statemint-local"]
PARACHAIN_COLLATORS = 2
PARACHAIN_NON_COLLATORS = 5

relay_chain = create_chain( "relay", POLKADOT, RELAY_CHAINSPEC )
node = create_node( relay_chain, "relay_bootnode" )
node.is_bootnode = true

RELAY_VALIDATORS.times do |n|
    node = create_node( relay_chain, "relay_v%03i" % [n + 1] )
    node.is_validator = true
end

RELAY_NON_VALIDATORS.times do |n|
    node = create_node( relay_chain, "relay_n%03i" % [n + 1] )
end

PARACHAIN_CHAINSPECS.each_with_index.each do |chainspec_name, p|
    parachain = create_parachain( relay_chain, "para%02i" % [p + 1], POLKADOT_COLLATOR, chainspec_name )

    node = create_node( parachain, "para%02i_bootnode" % [p + 1] )
    node.is_bootnode = true

    PARACHAIN_COLLATORS.times do |n|
        node = create_node( parachain, "para%02i_c%03i" % [p + 1, n + 1] )
        node.is_collator = true
    end

    PARACHAIN_NON_COLLATORS.times do |n|
        node = create_node( parachain, "para%02i_n%03i" % [p + 1, n + 1] )
    end
end

start_network relay_chain
