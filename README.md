# A simple script to launch huge Polkadot/Substrate testnets on a single machine

### Features

- Simple and easily customizable.
- Can launch networks of any size, with any number of validators, collators and parachains,
  where the only limiting factor is how much RAM and how much CPU horsepower you have.
- Can launch a local Polkadot, Kusama, Rococo and a Statemine chain.

### Requirements

1. Linux (may or may not work on macOS)
2. Ruby (v3.0 or later recommended)
3. `screen`
4. `polkadot` and `polkadot-collator` binaries

### Usage

1. Put `polkadot` and `polkadot-collator` in the root of this repository, or modify `config.rb`
2. Run one of the `start-*` scripts to start a network
3. Use `screen -r` to access a running node
4. `killall polkadot polkadot-collator` to kill the network

### Why yet another project to launch a testnet?

There are other existing projects like [polkadot-launch](https://github.com/paritytech/polkadot-launch)
or [parachain-launch](https://github.com/open-web3-stack/parachain-launch) to launch a testnet, so why another one?

Well, first and foremost, I wanted to learn how to manually set up a network from scratch, and to see how everything
fits together in general. The process was complicated enough that it didn't make sense to *actually* do it manually,
so I've recorded it step-by-step as a runnable script. And once I had such a script turning it into a generic tool
was fairly trivial after a bit of refactoring.

Also, I needed a few extra features which weren't available in those other projects, like the ability to launch
a network with an arbitrary number of validators, or the ability to easily define how a network should look like
programmatically (as opposed to using a config file), or to be able to easily experiment with the nodes locally
(so being forced to launch the nodes through Docker is an antifeature in this case), etc.

This is just my playground to run experiments in; feel free to use it if it also fits your usecase.
