Microsoft dev-tunnels Rust SDK (MIT), from
https://github.com/microsoft/dev-tunnels/tree/b73b0eb774b86a5b519c300f2f41c9072a66f663/rs

Only change: TCP_NODELAY on the relay websocket (src/connections/ws.rs,
lines marked "padcode"), which cuts per-keystroke latency in the terminal.

Second change: the relay's SSH algorithms are pinned (src/connections/relay_tunnel_client.rs,
"padcode"). PadCode's own SSH client enables russh's rs-crypto feature; Cargo unifies features,
so without the pin the relay would negotiate curve25519 and panic.
