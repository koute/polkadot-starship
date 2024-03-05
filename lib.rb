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
    10000.times do
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
    raise "command failed: #{cmd}" unless $?.exitstatus == 0
end

def capture( cmd )
    capture_raw( cmd ).strip
end

def capture_raw( cmd )
    STDERR.puts "#{VT_DARK}> #{cmd}#{VT_RESET}"
    output = `#{cmd}`
    raise "command failed: #{cmd}" unless $?.exitstatus == 0
    output
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
    :config,

    # Relaychain-only
    :parachains,
    :hrmp_channels,

    # Parachain-only
    :parachain_id,
    :relaychain,
    :is_dynamic
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
    chain.config = {}
    chain.is_dynamic = false

    FileUtils.mkdir_p chain.root_path
    chain
end

Node = Struct.new(
    :chain,
    :name,
    :root_path,
    :base_path,
    :key_path,
    :identity,
    :identity_path,
    :logs_path,
    :pid_path,
    :start,
    :relay_node,
    :para_node,
    :keys,

    # These can be used to customize the node.
    :binary,
    :phrase,
    :port,
    :rpc_port,
    :prometheus_port,
    :is_validator,
    :is_collator,
    :is_bootnode,
    :is_invulnerable,
    :balance,
    :in_peers,
    :out_peers,
    :extra_args,
    :env,
    :cpu_list,
    :start_delay,
    :relay_rpc_node,
    :pool_kbytes,
)

def create_node( chain, name, kind = nil )
    node = Node.new
    node.pool_kbytes = 128
    node.chain = chain
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

    unless kind == :parachain_embedded_relay_node
        node.binary = chain.binary
        node.pid_path = File.join node.root_path, "pid"
    end

    loop do
        $rpc_port_counter ||= 0
        port_offset = $rpc_port_counter
        $rpc_port_counter += 1

        node.rpc_port = BASE_PORT_WS + port_offset
        break if is_port_open? node.rpc_port
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
    node.env = {}
    node.in_peers = 25
    node.out_peers = 25
    node.start_delay = 0

    chain.nodes << node

    if chain.relaychain
        # Every parachain node also automatically runs a relay chain node.
        node.relay_node = create_node( chain.relaychain, name, :parachain_embedded_relay_node )
        node.relay_node.para_node = node
        # Since the parachain node will automatically start the relay chain
        # node we don't need to explicitly start it ourselves.
        node.relay_node.start = false
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

    # This changed a few times, to pick whichever is present.
    genesis_config = [
        chain.chainspec["genesis"]["runtime"],
        (chain.chainspec["genesis"]["runtime"] || {})["runtime_genesis_config"],
        (chain.chainspec["genesis"]["runtimeGenesis"] || {})["patch"]
    ].find { |cfg| cfg != nil && !cfg.empty? }

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

    if genesis_config["phragmenElection"]
        genesis_config["phragmenElection"]["members"].sort!
    end

    if chain.parachain_id
        chain.chainspec["para_id"] = chain.parachain_id
        genesis_config["parachainInfo"]["parachainId"] = chain.parachain_id
    end


    if chain.parachain_id == nil
        genesis_config["paras"] ||= {}
        genesis_config["paras"]["paras"] = []
        chain.parachains.each do |parachain|
            # This is technically unnecessary since we pass the relay chain's chainspec on the command line,
            # but let's just put a dummy name here to make sure it isn't actually used.
            parachain.chainspec["relay_chain"] = "does-not-exist"

            generate_chainspec parachain
            parachain_id = parachain.parachain_id

            maybe_raw = if parachain.is_dynamic
                "--raw"
            else
                ""
            end

            genesis_state = capture_raw "#{parachain.binary.shellescape} export-genesis-state --chain #{parachain.chainspec_raw_path.shellescape} #{maybe_raw}"
            genesis_wasm = capture_raw "#{parachain.binary.shellescape} export-genesis-wasm --chain #{parachain.chainspec_raw_path.shellescape} #{maybe_raw}"

            if parachain.is_dynamic
                File.write File.join(parachain.root_path, "genesis.state"), genesis_state
                File.write File.join(parachain.root_path, "genesis.wasm"), genesis_wasm
            else
                genesis_config["paras"]["paras"] << [parachain_id, [
                    genesis_state,
                    genesis_wasm,
                    true
                ]]
            end
        end

        config = genesis_config["configuration"]["config"]
        chain.config.each do |key, value|
            raise "key doesn't exist in chain config: '#{key}'" unless config.include? key
            config[key] = value
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
        "--base-path", node.base_path,
        "--chain", chain.chainspec_raw_path,
        "--node-key-file", node.key_path,
        "--name", node.name,
        "--no-mdns",
        "--db-cache", "1",
        "--trie-cache-size", "1048576",
        "--listen-addr", "/ip4/0.0.0.0/tcp/#{node.port}",
        "--no-hardware-benchmarks",
    ]

    if node.pool_kbytes
        args += [
            "--pool-kbytes", node.pool_kbytes,
        ]
    end

    if node.in_peers
        args += [
            "--in-peers", node.in_peers,
        ]
    end

    if node.out_peers
        args += [
            "--out-peers", node.out_peers
        ]
    end

    if node.rpc_port
        args += [
            "--rpc-methods", "unsafe",
            "--unsafe-rpc-external",
            "--rpc-port", node.rpc_port,
        ]
    end

    if node.prometheus_port
        args += [
            "--prometheus-port", node.prometheus_port
        ]
    end

    if node.relay_rpc_node
        args += [
            "--relay-chain-rpc-url", "ws://127.0.0.1:#{node.relay_rpc_node.rpc_port}"
        ]
    end

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
        if node.para_node
            # The Prometheus endpoint on the paranode side has only a bunch of "substrate_*" metrics;
            # not sure how useful it actually is, but let's just include it here anyway.
            targets << "127.0.0.1:#{node.para_node.prometheus_port}"
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

    config["scrape_configs"] << {
        "job_name" => "memory-usage",
        "static_configs" => [
            {
                "targets" => ["127.0.0.1:9089"]
            }
        ]
    }

    prometheus_path = File.join ROOT, "prometheus"
    FileUtils.mkdir_p prometheus_path
    File.write File.join( prometheus_path, "prometheus.yml" ), config.to_yaml
end

def start_monitoring
    raise "Port 9090 needs to be free to run Prometheus" unless is_port_open? 9090
    raise "Port 3000 needs to be free to run Grafana" unless is_port_open? 3000

    STDERR.puts "Starting Prometheus..."
    run "screen -L -Logfile #{(File.join ROOT, "prometheus-logs.txt").shellescape} -dmS prometheus docker run --rm --net=host --name starship-prometheus -v #{File.join( ROOT, "prometheus" ).shellescape}:/etc/prometheus prom/prometheus"

    STDERR.puts "Starting memory monitoring..."
    run "screen -dmS memory-logger bash -c 'cd tools/monitor-memory; exec cargo run --release #{ROOT.shellescape}'"

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

def launch_node node, chain, args
    cmd_outer = "screen -L -Logfile #{node.logs_path.shellescape} -dmS #{node.name.shellescape} nice -n 20 "
    if node.cpu_list
        cmd_outer << "taskset --cpu-list #{node.cpu_list.join(",")} "
    end

    cmd_inner = "#!/bin/bash\n"
    cmd_inner << "echo \"$$\" > #{node.pid_path.shellescape}\n"
    node.env.each do |key, value|
        cmd_inner << "export #{key}=#{value.shellescape}\n"
    end
    cmd_inner << "exec #{node.binary.shellescape} #{args}\n"

    inner_path = File.join node.root_path, "start_internal"
    File.write inner_path, cmd_inner
    FileUtils.chmod 0755, inner_path

    cmd_outer << "#{inner_path}"

    start_sh = File.join node.root_path, "start"
    File.write start_sh, cmd_outer
    FileUtils.chmod 0755, start_sh

    stop_sh = File.join node.root_path, "stop"
    File.write stop_sh, "rm -f #{node.pid_path.shellescape}\nscreen -S #{node.name.shellescape} -p 0 -X stuff '^C'"
    FileUtils.chmod 0755, stop_sh

    run cmd_outer
end

def start_network chain
    if chain.parachains.any? { |parachain| parachain.is_dynamic }
        `subxt --help`
        raise "you don't have 'subxt' installed" unless $?.exitstatus == 0
    end

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

    remaining = []
    chain.nodes.each do |node|
        next unless node.start
        remaining << [nil, node]
    end

    chain.parachains.each do |parachain|
        parachain.nodes.each do |node|
            remaining << [parachain, node]
        end
    end

    start_at = Time.now
    wait_until = start_at
    while remaining.empty? == false
        now = Time.now
        wait_until = nil
        remaining.delete_if do |parachain, node|
            launch_at = start_at + node.start_delay
            if node.relay_rpc_node
                begin
                    TCPSocket.new "127.0.0.1", node.relay_rpc_node.rpc_port
                    rescue Errno::ECONNREFUSED
                        launch_at = Time.now + 0.2
                end
            end

            if launch_at <= now
                if parachain == nil
                    STDERR.puts "Starting node '#{node.name}' on '#{chain.name}'..."
                    args = node_to_args chain, node
                    args = args.map(&:to_s).map(&:shellescape).join(" ")
                    launch_node node, chain, args
                else
                    STDERR.puts "Starting node '#{node.name}' on '#{parachain.name}'..."
                    # These args are for the parachain node.
                    args = node_to_args parachain, node
                    args += ["--"]
                    # And these args are for the relay chain node.
                    args += node_to_args chain, node.relay_node
                    args = args.map(&:to_s).map(&:shellescape).join(" ")
                    launch_node node, parachain, args
                end
                true
            else
                if wait_until == nil
                    wait_until = launch_at
                else
                    wait_until = [wait_until, launch_at].min
                end
                false
            end
        end

        if wait_until != nil
            sleep 0.1 while wait_until > Time.now
        end
    end

    STDERR.puts "#{VT_GREEN}Finished launching the network!#{VT_RESET}"
    STDERR.puts
end

def register_parachains chain
    return unless chain.parachains.any? { |parachain| parachain.is_dynamic }
    min_pool_size = chain.parachains.filter { |parachain| parachain.is_dynamic }.map { |parachain| File.size(File.join(parachain.root_path, "genesis.wasm")) }.max / 1024
    rpc_nodes = chain.nodes.select { |node| node.pool_kbytes == nil || node.pool_kbytes >= min_pool_size }
    metadata_path = File.join chain.root_path, "metadata.scale"

    if rpc_nodes.empty?
        raise "No RPC nodes found with big enough txpools to register the parachains; set 'pool_kbytes' and try again."
    end

    puts "RPC nodes with big enough txpool: #{rpc_nodes.length}"
    Dir.chdir("tools/register-parachain") do
        run "cargo build -q -p register-parachain --release"

        STDERR.puts "Waiting for RPC port..."
        wait_for_port rpc_nodes[0].rpc_port

        run "subxt metadata -f bytes --url 'ws://127.0.0.1:#{rpc_nodes[0].rpc_port}' > #{metadata_path.shellescape}"
        if File.read("src/metadata.scale") != File.read(metadata_path)
            STDERR.puts "Generated new metadata!"
            FileUtils.cp metadata_path, "src/metadata.scale"
        end

        # Doing more than one in parallel seems not be useful.
        parallel_registrations = 1

        nth_rpc_node = 0
        chain.parachains.filter { |parachain| parachain.is_dynamic }.each_slice(parallel_registrations) do |parachains|
            parachains = parachains.map do |parachain|
                rpc_node = rpc_nodes[nth_rpc_node % rpc_nodes.length]
                nth_rpc_node += 1
                [parachain, rpc_node]
            end

            threads = []
            parachains.each do |parachain, rpc_node|
                threads << Thread.new do
                    STDERR.puts "Registering parachain '#{parachain.name}'... (id = #{parachain.parachain_id}, RPC node = #{rpc_node.name}, RPC node txpool size = #{rpc_node.pool_kbytes}kB)"
                    run "cargo run -q -p register-parachain --release 'ws://127.0.0.1:#{rpc_node.rpc_port}' #{parachain.parachain_id} #{File.join(parachain.root_path, "genesis.state").shellescape} #{File.join(parachain.root_path, "genesis.wasm").shellescape}"
                end
            end

            threads.each do |thread|
                thread.join
            end
        end
    end

    STDERR.puts "#{VT_GREEN}Finished launching all parachains!#{VT_RESET}"
    STDERR.puts
end

def stop_network
    system "killall -q #{File.basename POLKADOT}"
    system "killall -q #{File.basename POLKADOT_COLLATOR}"
end

def stop_monitoring
    system "docker stop starship-prometheus &> /dev/null"
    system "docker stop starship-grafana &> /dev/null"
    system "killall -q monitor-memory"
end

def prepare_workspace
    # Kill any previous network which might still be running.
    stop_network
    stop_monitoring

    FileUtils.rm_rf ROOT
    FileUtils.mkdir_p ROOT
end
