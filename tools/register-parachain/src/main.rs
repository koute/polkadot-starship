#[subxt::subxt(runtime_metadata_path = "src/metadata.scale")]
pub mod polkadot {}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let url = args.next().unwrap();
    let id = args.next().unwrap().parse().unwrap();
    let genesis = std::fs::read(args.next().unwrap()).unwrap();
    let code = std::fs::read(args.next().unwrap()).unwrap();
    assert!(args.next().is_none());

    let client = subxt::client::OnlineClient::<subxt::config::substrate::SubstrateConfig>::from_url(url).await.unwrap();
    loop {
        let call = self::polkadot::sudo::calls::types::sudo::Call::ParasSudoWrapper(
            self::polkadot::runtime_types::polkadot_runtime_common::paras_sudo_wrapper::pallet::Call::sudo_schedule_para_initialize {
                id: self::polkadot::runtime_types::polkadot_parachain_primitives::primitives::Id(id),
                genesis: self::polkadot::paras_sudo_wrapper::calls::types::sudo_schedule_para_initialize::Genesis {
                    genesis_head: self::polkadot::runtime_types::polkadot_parachain_primitives::primitives::HeadData(genesis.clone()),
                    validation_code: self::polkadot::runtime_types::polkadot_parachain_primitives::primitives::ValidationCode(code.clone()),
                    para_kind: true,
                }
            }
        );

        let call = self::polkadot::tx().sudo().sudo(call);
        let account = subxt_signer::sr25519::dev::alice();

        let tx = match client.tx().sign_and_submit_then_watch_default(&call, &account).await {
            Ok(tx) => tx,
            Err(error) => {
                let error_s = format!("{error:?}");
                if error_s.contains("The transaction couldn't enter the pool because of the limit") {
                    println!("WARN: Couldn't register parachain {id} due to a transaction pool limit; retrying...");
                    std::thread::sleep(core::time::Duration::from_secs(1));
                    continue;
                }

                if error_s.contains("The transaction has too low priority to replace another transaction already in the pool") {
                    std::thread::sleep(core::time::Duration::from_secs(1));
                    continue;
                }

                if error_s.contains("Transaction is outdated") || error_s.contains("BlockNotFound") {
                    continue;
                }

                panic!("{error}");
            }
        };

        println!("Registration for parachain {id} submitted; waiting for finalization...");

        if let Err(error) = tx.wait_for_finalized_success().await {
            let error_s = format!("{error:?}");
            if error_s.contains("BlockNotFound") {
                continue;
            }

            panic!("{error}");
        }

        println!("Parachain registered: {id}");
        break;
    }
}
