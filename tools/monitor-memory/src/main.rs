use tokio::net::TcpListener;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use std::fmt::Write;
use std::path::Path;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = std::env::args().skip(1).next().expect("missing arg: path to the testnet root");
    let listener = TcpListener::bind("127.0.0.1:9089").await?;
    loop {
        let (mut socket, _) = listener.accept().await?;
        let root = root.clone();
        tokio::spawn(async move {
            let mut buffer = [0; 1024];
            loop {
                let count = match socket.read(&mut buffer).await {
                    Ok(count) if count == 0 => break,
                    Ok(count) => count,
                    Err(error) => {
                        eprintln!("Failed to read from socket: {:?}", error);
                        return;
                    }
                };

                // TODO: This is janky, but should work.
                if buffer[..count].contains(&b'\n') {
                    break;
                }
            }

            let mut buffer = String::new();
            write!(&mut buffer, "HTTP/1.1 200\r\n").unwrap();
            write!(&mut buffer, "Content-Type: text/plain; version=0.0.4\r\n").unwrap();
            write!(&mut buffer, "\r\n").unwrap();

            let mut queue = Vec::new();
            for entry in std::fs::read_dir(root).unwrap() {
                let entry = entry.unwrap();
                let path = entry.path().join("nodes");
                if !path.exists() {
                    continue;
                }
                for entry in std::fs::read_dir(path).unwrap() {
                    let entry = entry.unwrap();
                    let path = entry.path();
                    let name = path.file_name().unwrap().to_str().unwrap().to_owned();
                    let pid_path = entry.path().join("pid");
                    let future = tokio::spawn(async move {
                        let mut output = String::new();
                        if let Ok(pid) = tokio::fs::read_to_string(pid_path).await {
                            if let Ok(data) = tokio::fs::read_to_string(Path::new("/proc").join(pid.trim()).join("smaps_rollup")).await {
                                let position = data.find("Rss: ").unwrap() + 4;
                                let slice = data[position..].trim_start();
                                let length = slice.bytes().take_while(u8::is_ascii_digit).count();
                                let rss: u64 = slice[..length].parse().unwrap();
                                output = format!("memory_usage_rss{{domain=\"local\",instance=\"{}\"}} {}\n", name, rss * 1024);
                            }
                        }
                        output
                    });
                    queue.push(future);
                }
            }

            for future in queue {
                if let Ok(line) = future.await {
                    buffer.push_str(&line);
                }
            }

            let _ = socket.write_all(buffer.as_bytes()).await;
        });
    }
}
