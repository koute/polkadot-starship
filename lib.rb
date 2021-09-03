#!/usr/bin/ruby

require "shellwords"
require "fileutils"
require "json"
require "yaml"
require "socket"
require "set"

require_relative "config.rb"

USE_POLKADOT_TO_REGISTER_KEYS = false

VT_DARK = "\e[1;30m"
VT_GREEN = "\e[1;32m"
VT_RESET = "\e[0m"

`screen -v`
raise "you don't have 'screen' installed" unless $?.exitstatus == 0

`#{POLKADOT.shellescape} --version`
raise "'polkadot' binary is not accessible" unless $?.exitstatus == 0

`#{POLKADOT_COLLATOR.shellescape} --version`
raise "'polkadot-collator' binary is not accessible" unless $?.exitstatus == 0

def is_port_open? port
    socket = TCPServer::open "127.0.0.1", port
    socket.close
    return true

    rescue Errno::EADDRINUSE
        false
end

def wait_for_port port
    1000.times do
        socket = TCPSocket.new "127.0.0.1", port
        socket.close
        return
        rescue Errno::ECONNREFUSED
            sleep 0.1
            next
    end

    raise "timeout waiting for port"
end

def run( cmd )
    STDERR.puts "#{VT_DARK}> #{cmd}#{VT_RESET}"
    system cmd
    raise "command failed" unless $?.exitstatus == 0
end

def capture( cmd )
    STDERR.puts "#{VT_DARK}> #{cmd}#{VT_RESET}"
    output = `#{cmd}`
    raise "command failed" unless $?.exitstatus == 0
    output.strip
end

Keys = Struct.new(
    :phrase,
    :stash_public_sr25519_ss58,
    :primary_public_sr25519_ss58,
    :primary_public_sr25519,
    :primary_public_ed25519_ss58,
    :primary_public_ed25519,
    :primary_public_ecdsa_ss58,
    :primary_public_ecdsa
)

def generate_keys phrase = nil
    keys = Keys.new

    # Generate the secret phrase from which all of the keys are derived from.
    # (This is essentially our private key.)
    if phrase
        keys.phrase = phrase
    else
        out = JSON.parse capture( "#{POLKADOT.shellescape} key generate --output-type json" )
        keys.phrase = out[ "secretPhrase" ]
    end

    # And then generate every type of a key we'll need.

    out = JSON.parse capture( "#{POLKADOT.shellescape} key inspect --scheme sr25519 --output-type json #{(keys.phrase + "//stash").shellescape}" )
    keys.stash_public_sr25519_ss58 = out[ "ss58PublicKey" ]

    out = JSON.parse capture( "#{POLKADOT.shellescape} key inspect --scheme sr25519 --output-type json #{keys.phrase.shellescape}" )
    keys.primary_public_sr25519_ss58 = out[ "ss58PublicKey" ]
    keys.primary_public_sr25519 = out[ "publicKey" ]

    out = JSON.parse capture( "#{POLKADOT.shellescape} key inspect --scheme ed25519 --output-type json #{keys.phrase.shellescape}" )
    keys.primary_public_ed25519_ss58 = out[ "ss58PublicKey" ]
    keys.primary_public_ed25519 = out[ "publicKey" ]

    out = JSON.parse capture( "#{POLKADOT.shellescape} key inspect --scheme ecdsa --output-type json #{keys.phrase.shellescape}" )
    keys.primary_public_ecdsa_ss58 = out[ "ss58PublicKey" ]
    keys.primary_public_ecdsa = out[ "publicKey" ]

    keys
end

def insert_keys( chainspec_path, node )
    # Here we physically insert the private keys into a given node.
    #
    # Not every key type is needed for every kind of a chain, but
    # we'll just always add all of them for simplicity.
    chain_id = JSON.parse( File.read( chainspec_path ) )[ "id" ]
    [
        ["aura", "sr25519", node.keys.primary_public_sr25519],
        ["babe", "sr25519", node.keys.primary_public_sr25519],
        ["imon", "sr25519", node.keys.primary_public_sr25519],
        ["gran", "ed25519", node.keys.primary_public_ed25519],
        ["audi", "sr25519", node.keys.primary_public_sr25519],
        ["asgn", "sr25519", node.keys.primary_public_sr25519],
        ["para", "sr25519", node.keys.primary_public_sr25519]
    ].each do |kind, scheme, key|
        filename = kind.chars.map { |c| "%02x" % [c.ord] }.join("") + key.sub( /^0x/, "" )
        path = File.join node.base_path, "chains", chain_id, "keystore", filename
        contents = "\"#{node.keys.phrase}\""

        # We can add the keys either through the polkadot binary, or manually.
        #
        # Doing this through polkadot is very slow for some reason, so let's just do it manually,
        # but we'll leave this codepath here in case the manual way of doing it breaks in the future.
        if USE_POLKADOT_TO_REGISTER_KEYS
            run "#{POLKADOT.shellescape} key insert -d #{node.base_path.shellescape} --key-type #{kind} --scheme #{scheme} --chain #{CHAINSPEC.shellescape} --suri #{node.keys.phrase.shellescape}"

            # Make sure it was added in a way we expect it should.
            raise unless File.exist? path
            raise unless File.read( path ).strip == contents
        else
            FileUtils.mkdir_p File.dirname( path )
            File.write path, contents
        end
    end
end

class Chain < Struct.new(
    :name,
    :binary,
    :root_path,
    :chainspec_path,
    :chainspec_raw_path,
    :chainspec,
    :nodes,

    # Relaychain-only
    :parachains,
    :hrmp_channels,

    # Parachain-only
    :parachain_id,
    :relaychain
)
    def inspect
        "Chain(#{self.name})"
    end
end

def create_chain( name, binary, base_chainspec )
    chain = Chain.new

    chain.name = name

    # The path to the `polkadot` or `polkadot-collator` we'll later use.
    chain.binary = File.expand_path binary
    # The path under which we'll store all of the chain's files.
    chain.root_path = File.join ROOT, chain.name
    # Where we'll later store the human-readable chainspec.
    chain.chainspec_path = File.join chain.root_path, "chainspec.json"
    # Where we'll later store the raw chainspec.
    chain.chainspec_raw_path = File.join chain.root_path, "chainspec_raw.json"
    # The default chainspec itself, which we'll later modify.
    chain.chainspec = JSON.parse capture "#{chain.binary.shellescape} build-spec --chain #{base_chainspec.shellescape} --disable-default-bootnode 2> /dev/null"
    # The list of nodes for this chain.
    chain.nodes = []
    # The list of parachains attached to this chain.
    chain.parachains = []
    # The list of HRMP channels between parachains on this relay chain.
    chain.hrmp_channels = []

    FileUtils.mkdir_p chain.root_path
    chain
end

Node = Struct.new(
    :name,
    :root_path,
    :base_path,
    :key_path,
    :identity,
    :identity_path,
    :logs_path,
    :start,
    :relaynode,
    :paranode,
    :keys,

    # These can be used to customize the node.
    :phrase,
    :port,
    :ws_port,
    :prometheus_port,
    :is_validator,
    :is_collator,
    :is_bootnode,
    :is_invulnerable,
    :balance,
    :extra_args
)

def create_node( chain, name )
    node = Node.new
    node.name = name
    node.root_path = File.join chain.root_path, "nodes", node.name
    node.base_path = File.join node.root_path, "base"
    node.key_path = File.join node.root_path, "key"
    node.identity_path = File.join node.root_path, "identity"
    node.logs_path = File.join node.root_path, "logs.txt"
    FileUtils.mkdir_p node.root_path

    # Here we generate the libp2p key; this is used by the nodes to communicate with each other.
    run "#{POLKADOT.shellescape} key generate-node-key 1> #{node.key_path.shellescape} 2> #{node.identity_path.shellescape}"
    node.identity = File.read( node.identity_path ).strip

    # Find a pair of free ports, one for the libp2p communication, and another for the websocket for RPC calls.
    loop do
        $base_port_counter ||= 0
        port_offset = $base_port_counter
        $base_port_counter += 1

        node.port = BASE_PORT_NODE + port_offset
        break if is_port_open? node.port
    end

    loop do
        $ws_port_counter ||= 0
        port_offset = $ws_port_counter
        $ws_port_counter += 1

        node.ws_port = BASE_PORT_WS + port_offset
        break if is_port_open? node.ws_port
    end

    loop do
        $prometheus_port_counter ||= 0
        port_offset = $prometheus_port_counter
        $prometheus_port_counter += 1

        node.prometheus_port = BASE_PORT_PROMETHEUS + port_offset
        break if is_port_open? node.prometheus_port
    end

    node.is_validator = false
    node.is_collator = false
    node.is_bootnode = false
    node.is_invulnerable = false
    node.balance = 1000000000000000000
    node.start = true
    node.extra_args = []

    chain.nodes << node

    if chain.relaychain
        # Every parachain node also automatically runs a relay chain node.
        node.relaynode = create_node( chain.relaychain, name )
        node.relaynode.paranode = node
        # Since the parachain node will automatically start the relay chain
        # node we don't need to explicitly start it ourselves.
        node.relaynode.start = false
    end

    node
end

def create_parachain( relaychain, name, binary, base_chainspec )
    $parachain_counter ||= 0
    parachain_id = $parachain_counter + 1000
    $parachain_counter += 1

    parachain = create_chain( name, binary, base_chainspec )
    parachain.parachain_id = parachain_id
    parachain.relaychain = relaychain
    relaychain.parachains << parachain

    parachain
end

HrmpChannel = Struct.new(
    :src,
    :dst,

    :max_capacity,
    :max_message_size
)

def connect_with_hrmp( parachain_src, parachain_dst )
    raise unless parachain_src.relaychain.equal? parachain_dst.relaychain
    channel = HrmpChannel.new
    channel.src = parachain_src
    channel.dst = parachain_dst
    channel.max_capacity = 8
    channel.max_message_size = 512
    parachain_src.relaychain.hrmp_channels << channel

    channel
end

def generate_chainspec chain
    STDERR.puts "Generating chainspec for '#{chain.name}'..."

    genesis_config = chain.chainspec["genesis"]["runtime"]
    if genesis_config.include? "runtime_genesis_config"
        # For Rococo, which keeps the genesis configuration under a different key for some reason.
        genesis_config = genesis_config["runtime_genesis_config"]
    end

    # Clear out all of the defaults.
    # These usually contain the keys for built-in development accounts like Alice, Bob, etc.
    if genesis_config["staking"]
        genesis_config["staking"]["stakers"] = []
        genesis_config["staking"]["invulnerables"] = []
        genesis_config["staking"]["validatorCount"] = 0
    end

    if genesis_config["collatorSelection"]
        genesis_config["collatorSelection"]["invulnerables"] = []
    end

    if genesis_config["session"]
        genesis_config["session"]["keys"].clear
    end

    if genesis_config["aura"]
        genesis_config["aura"]["authorities"].clear
    end

    # We leave the default balances for the development accounts intact
    # since Polkadot.js has those accounts already built-in so it's easier
    # to play around if there are already tokens in them.
    pubkeys = Set.new chain.nodes.map { |node| node.keys.stash_public_sr25519_ss58 }
    genesis_config["balances"]["balances"].delete_if { |balance| pubkeys.include? balance[0] }

    chain.chainspec["bootNodes"] = []
    chain.nodes.each do |node|
        if node.is_bootnode
            # Other nodes will connect to this node when joining the network.
            chain.chainspec["bootNodes"] << "/ip4/127.0.0.1/tcp/#{node.port}/p2p/#{node.identity}"
        end

        if node.balance > 0
            # The amount of tokens the node has on hand.
            genesis_config["balances"]["balances"] << [
                node.keys.stash_public_sr25519_ss58,
                node.balance
            ]
        end

        if node.is_validator
            if genesis_config["staking"]
                genesis_config["staking"]["stakers"] << [
                    node.keys.stash_public_sr25519_ss58,
                    node.keys.primary_public_sr25519_ss58,
                    1000000000000,
                    "Validator"
                ]
                genesis_config["staking"]["validatorCount"] += 1

                if node.is_invulnerable
                    genesis_config["staking"]["invulnerables"] << node.keys.stash_public_sr25519_ss58
                end
            end
        end

        if node.is_collator
            # Looks like this is required for collators on Statemint.
            if genesis_config["collatorSelection"]
                genesis_config["collatorSelection"]["invulnerables"] << node.keys.primary_public_sr25519_ss58
                # This doesn't seem necessary?
                #   genesis_config["collatorSelection"]["desiredCandidates"] = 1
            end
        end

        if node.is_validator || node.is_collator
            if genesis_config["session"]
                key = nil
                if chain.parachain_id
                    key = node.keys.primary_public_sr25519_ss58
                else
                    key = node.keys.stash_public_sr25519_ss58
                end

                genesis_config["session"]["keys"] << [
                    key,
                    key,
                    {
                        # Not all of these are always need, but we'll add them anyway
                        # just for good measure.
                        "grandpa" => node.keys.primary_public_ed25519_ss58,
                        "babe" => node.keys.primary_public_sr25519_ss58,
                        "im_online" => node.keys.primary_public_sr25519_ss58,
                        "para_validator" => node.keys.primary_public_sr25519_ss58,
                        "para_assignment" => node.keys.primary_public_sr25519_ss58,
                        "authority_discovery" => node.keys.primary_public_sr25519_ss58,
                        "beefy" => node.keys.primary_public_ecdsa_ss58,
                        "aura" => node.keys.primary_public_sr25519_ss58
                    }
                ]
            else
                # If the "session" pallet is used then that is used to figure out who the authorities are;
                # otherwise they're just hardcoded here.
                if genesis_config["babe"]
                    # https://substrate.dev/rustdocs/latest/pallet_babe/pallet/struct.GenesisConfig.html
                    genesis_config["babe"]["authorities"] << [node.keys.primary_public_sr25519_ss58, 1]
                end
                if genesis_config["grandpa"]
                    # https://substrate.dev/rustdocs/latest/pallet_grandpa/pallet/struct.GenesisConfig.html
                    genesis_config["grandpa"]["authorities"] << [node.keys.primary_public_ed25519_ss58, 1]
                end
                if genesis_config["aura"]
                    # https://substrate.dev/rustdocs/latest/pallet_aura/pallet/struct.GenesisConfig.html
                    genesis_config["aura"]["authorities"] << node.keys.primary_public_sr25519_ss58
                end
            end
        end
    end

    if chain.parachain_id
        chain.chainspec["para_id"] = chain.parachain_id
        genesis_config["parachainInfo"]["parachainId"] = chain.parachain_id
    end

    if genesis_config["paras"]
        genesis_config["paras"]["paras"] = []
        chain.parachains.each do |parachain|
            # This is technically unnecessary since we pass the relay chain's chainspec on the command line,
            # but let's just put a dummy name here to make sure it isn't actually used.
            parachain.chainspec["relay_chain"] = "does-not-exist"

            generate_chainspec parachain

            parachain_id = parachain.parachain_id
            genesis_state = capture "#{parachain.binary.shellescape} export-genesis-state --parachain-id #{parachain_id} --chain #{parachain.chainspec_raw_path.shellescape}"
            genesis_wasm = capture "#{parachain.binary.shellescape} export-genesis-wasm --chain #{parachain.chainspec_raw_path.shellescape}"
            genesis_config["paras"]["paras"] << [parachain_id, [
                genesis_state,
                genesis_wasm,
                true
            ]]
        end
    end

    if genesis_config["hrmp"]
        genesis_config["hrmp"]["preopenHrmpChannels"] = []
        chain.hrmp_channels.each do |channel|
            genesis_config["hrmp"]["preopenHrmpChannels"] << [
                channel.src.parachain_id,
                channel.dst.parachain_id,
                channel.max_capacity,
                channel.max_message_size
            ]
        end
    end

    File.write chain.chainspec_path, JSON.pretty_generate( chain.chainspec )

    # We need to convert the human readable chainspec into the raw variant
    # which has all of the genesis keys hashes and values SCALE encoded.
    run "#{chain.binary.shellescape} build-spec --chain #{chain.chainspec_path.shellescape} --raw --disable-default-bootnode > #{chain.chainspec_raw_path.shellescape} 2> /dev/null"
end

def node_to_args chain, node
    args = [
        "--rpc-methods", "Unsafe",
        "--execution", "wasm",
        "--base-path", node.base_path,
        "--chain", chain.chainspec_raw_path,
        "--ws-port", node.ws_port,
        "--node-key-file", node.key_path,
        "--name", node.name,
        "--discover-local=false",
        "--no-mdns",
        "--db-cache", "2",
        "--pool-kbytes", "2048",
        "--listen-addr", "/ip4/0.0.0.0/tcp/#{node.port}",
        "--prometheus-port", node.prometheus_port
    ]

    args += ["--validator"] if node.is_validator
    args += ["--collator"] if node.is_collator
    args += node.extra_args
    args
end

def generate_prometheus_config chain
    config = {
        "global" => {
            "scrape_interval" => "5s",
            "evaluation_interval" => "5s"
        },
        "scrape_configs" => []
    }

    chain.nodes.each do |node|
        targets = ["127.0.0.1:#{node.prometheus_port}"]
        if node.paranode
            # The Prometheus endpoint on the paranode side has only a bunch of "substrate_*" metrics;
            # not sure how useful it actually is, but let's just include it here anyway.
            targets << "127.0.0.1:#{node.paranode.prometheus_port}"
        end
        config["scrape_configs"] << {
            "job_name" => node.name,
            "static_configs" => [
                {
                    "targets" => targets,
                    "labels" => {
                        # For compatibility with production dashboards.
                        "domain" => "local",
                        "instance" => node.name
                    }
                }
            ]
        }
    end

    prometheus_path = File.join ROOT, "prometheus"
    FileUtils.mkdir_p prometheus_path
    File.write File.join( prometheus_path, "prometheus.yml" ), config.to_yaml
end

def start_monitoring
    STDERR.puts "Starting Prometheus..."
    run "screen -L -Logfile #{(File.join ROOT, "prometheus-logs.txt").shellescape} -dmS prometheus docker run --rm --net=host --name starship-prometheus -v #{File.join( ROOT, "prometheus" ).shellescape}:/etc/prometheus prom/prometheus"

    STDERR.puts "Starting Grafana..."
    run "screen -L -Logfile #{(File.join ROOT, "grafana-logs.txt").shellescape} -dmS grafana docker run --rm --net=host --name starship-grafana grafana/grafana"

    STDERR.puts "Waiting for Grafana to start..."
    wait_for_port 3000

    cookie_jar = File.join ROOT, "grafana-cookies"
    STDERR.puts "Configuring Grafana..."
    payload = {
        "user" => "admin",
        "email" => "",
        "password" => "admin"
    }.to_json
    run "curl -s -c #{cookie_jar.shellescape} 'http://localhost:3000/login' -H 'Content-Type: application/json' --data-binary #{payload.shellescape} > /dev/null"

    payload = {
        "name" => "Prometheus",
        "type" => "prometheus",
        "access" => "proxy",
        "url" => "http://localhost:9090",
        "isDefault" => true
    }.to_json
    run "curl -s -b #{cookie_jar.shellescape} 'http://localhost:3000/api/datasources' -X POST -H 'Content-Type: application/json' --data-binary #{payload.shellescape} > /dev/null"

    if File.exist? "default-dashboard.json"
        dashboard = JSON.parse( File.read( "default-dashboard.json" ) )
        payload = {
            "dashboard" => dashboard,
            "inputs" => [
                "name" => "DS_PROMETHEUS",
                "pluginId" => "prometheus",
                "type" => "datasource",
                "value" => "Prometheus"
            ],
            "overwrite" => true
        }.to_json

        payload_path = File.join ROOT, "grafana-dashboard-import.json"
        File.write payload_path, payload

        reply = capture "curl -s -b #{cookie_jar.shellescape} 'http://localhost:3000/api/dashboards/import' -X POST -H 'Content-Type: application/json' --data-binary #{("@" + payload_path).shellescape}"
        STDERR.puts JSON.parse( reply )["message"]
    end

    STDERR.puts "#{VT_GREEN}Finished launching monitoring!#{VT_RESET}"
    STDERR.puts "#{VT_GREEN}Grafana available at: http://localhost:3000 (use 'admin' as username/password)#{VT_RESET}"
    STDERR.puts
end

def start_network chain
    generate_prometheus_config chain

    chain.nodes.each do |node|
        STDERR.puts "Generating keys for relay chain node '#{node.name}' (phrase = #{node.phrase.inspect})..."
        node.keys = generate_keys node.phrase
    end

    chain.parachains.each do |parachain|
        parachain.nodes.each do |node|
            STDERR.puts "Generating keys for parachain node '#{node.name}' (phrase = #{node.phrase.inspect})..."
            node.keys = generate_keys node.phrase
        end
    end

    generate_chainspec chain

    chain.nodes.each do |node|
        insert_keys chain.chainspec_path, node
    end

    chain.parachains.each do |parachain|
        parachain.nodes.each do |node|
            insert_keys parachain.chainspec_path, node
        end
    end

    chain.nodes.each do |node|
        next unless node.start
        STDERR.puts "Starting node '#{node.name}' on '#{chain.name}'..."
        args = node_to_args chain, node
        args = args.map(&:to_s).map(&:shellescape).join(" ")
        cmd = "screen -L -Logfile #{node.logs_path.shellescape} -dmS #{node.name.shellescape} #{chain.binary.shellescape} #{args}"
        start_sh = File.join node.root_path, "start.sh"
        File.write start_sh, cmd
        FileUtils.chmod 0755, start_sh
        run cmd

        stop_sh = File.join node.root_path, "stop.sh"
        File.write stop_sh, "screen -S #{node.name.shellescape} -p 0 -X stuff '^C'"
        FileUtils.chmod 0755, stop_sh
    end

    chain.parachains.each do |parachain|
        parachain.nodes.each do |node|
            STDERR.puts "Starting node '#{node.name}' on '#{parachain.name}'..."
            # These args are for the parachain node.
            args = node_to_args parachain, node
            args += ["--"]
            # And these args are for the relay chain node.
            args += node_to_args chain, node.relaynode
            args = args.map(&:to_s).map(&:shellescape).join(" ")
            cmd = "screen -L -Logfile #{node.logs_path.shellescape} -dmS #{node.name.shellescape} #{parachain.binary.shellescape} #{args}"
            start_sh = File.join node.root_path, "start.sh"
            File.write start_sh, cmd
            FileUtils.chmod 0755, start_sh
            run cmd

            stop_sh = File.join node.root_path, "stop.sh"
            File.write stop_sh, "screen -S #{node.name.shellescape} -p 0 -X stuff '^C'"
            FileUtils.chmod 0755, stop_sh
        end
    end

    STDERR.puts "#{VT_GREEN}Finished launching the network!#{VT_RESET}"
    STDERR.puts
end

def stop_network
    # Kill any previous network which might still be running.
    system "killall -q #{File.basename POLKADOT}"
    system "killall -q #{File.basename POLKADOT_COLLATOR}"
    system "docker stop starship-prometheus &> /dev/null"
    system "docker stop starship-grafana &> /dev/null"
end

def prepare_workspace
    stop_network

    FileUtils.rm_rf ROOT
    FileUtils.mkdir_p ROOT
end
