# Path to your `polkadot` binary
# Grab it from here: https://github.com/paritytech/polkadot
POLKADOT = "./binaries/polkadot"

# Path to your `polkadot-parachain` binary
# Grab it from here: https://github.com/paritytech/cumulus
POLKADOT_COLLATOR = "./binaries/polkadot-parachain"

# The path where your nodes' files will reside
#    WARNING: Whatever you put here will be deleted with "rm -Rf"
ROOT = "/tmp/local-testnet"

# Start assigning the libp2p ports starting at this port
BASE_PORT_NODE = 30333

# Start assigning the websocket ports starting at this port
BASE_PORT_WS = 9944

# Start assigning nodes' Prometheus ports starting at this port
BASE_PORT_PROMETHEUS = 9091
