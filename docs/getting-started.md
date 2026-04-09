# Getting Started

## Requirements

- Zig `0.15.2` or newer

## Build

Build everything:

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

## Run The Examples

Start the server:

```bash
./zig-out/bin/zigenet-server
```

Start the client in another terminal:

```bash
./zig-out/bin/zigenet-client
```

Expected result:

- the server binds to `0.0.0.0:17091`
- the client connects to `127.0.0.1:17091`
- the client sends a small reliable packet
- the server prints a receive event

## Use The Parity Helper

The parity helper is a small Zig tool for checking useful protocol details:

```bash
./zig-out/bin/parity-harness fixtures
./zig-out/bin/parity-harness sizes
./zig-out/bin/parity-harness crc32 123456789
```

What it does:

- `fixtures`
  prints serialized command fixtures
- `sizes`
  prints protocol command wire sizes
- `crc32`
  prints the CRC32 checksum used by the project

## Using The Library

Typical flow:

1. Create a `Host`
2. Attach a transport
3. Connect to a peer or wait for traffic
4. Repeatedly call `service()`
5. Send packets with `Peer.send()`
6. Call `flush()` when you want queued traffic sent immediately

Minimal flow:

```zig
const std = @import("std");
const zigenet = @import("zigenet");

pub fn main() !void {
    const transport = try zigenet.transport.unix.UdpSocket.bind(std.heap.page_allocator, null);
    var host = try zigenet.Host.withTransport(std.heap.page_allocator, .{
        .peer_limit = 1,
        .channel_limit = 2,
        .using_new_packet = false,
        .using_new_packet_for_server = false,
    }, transport);
    defer host.deinit();

    const peer = try host.connect(zigenet.Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 17091), 2, 0);
    _ = peer;
    try host.flush();
}
```

## Choosing New Packet Flags

The main compatibility flags are:

- `using_new_packet`
  enables outgoing new-packet header behavior
- `using_new_packet_for_server`
  enables incoming server-side new-packet parsing and integrity checks

For general local testing and simple examples, leave both flags `false`.

For Growtopia private server work, enable `using_new_packet_for_server` when you need the custom header behavior.
