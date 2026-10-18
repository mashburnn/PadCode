Microsoft dev-tunnels Rust SDK (MIT), from
https://github.com/microsoft/dev-tunnels/tree/b73b0eb774b86a5b519c300f2f41c9072a66f663/rs

Only change: TCP_NODELAY on the relay websocket (src/connections/ws.rs,
lines marked "padcode"), which cuts per-keystroke latency in the terminal.
