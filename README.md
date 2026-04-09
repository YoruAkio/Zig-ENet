# Zig ENet

A Zig-first rewrite of the ENet networking library, focused specifically on Growtopia private server development.

This project ports the core ENet-style runtime to Zig and keeps the public surface focused on Zig-native types and ownership rules instead of a line-by-line C API clone. It is built mainly for Growtopia private server networking and protocol work.

## Features

- UDP host/peer model
- Reliable, unreliable, and unsequenced packet paths
- Fragmentation and reassembly
- Acknowledgements, resend timeouts, RTT tracking, and ping handling
- Bandwidth and throttle control paths
- Optional checksum support
- Zig-native range coder compression
- Unix and Windows transport backends
- Growtopia-style new-packet header support

## Build

Requirements:

- Zig `0.15.2` or newer

Build the library and binaries:

```bash
zig build
```

Run tests:

```bash
zig build test
```

Cross-build for Windows:

```bash
zig build -Dtarget=x86_64-windows-gnu
```

## Examples

Run the server:

```bash
./zig-out/bin/zigenet-server
```

Run the client in another terminal:

```bash
./zig-out/bin/zigenet-client
```

## Parity Helper

The project includes a small Zig utility for inspecting wire fixtures and constants:

```bash
./zig-out/bin/parity-harness fixtures
./zig-out/bin/parity-harness sizes
./zig-out/bin/parity-harness crc32 123456789
```

## API Shape

Main Zig-facing types:

- `Host`
- `Peer`
- `Packet`
- `Event`
- `Address`
- `HostConfig`

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
