# Architecture

## Overview

The project is split into a few clear layers so protocol code is not tightly coupled to sockets or platform code.

## Main Modules

- [src/address.zig](../src/address.zig)
  address type and conversion helpers
- [src/packet.zig](../src/packet.zig)
  packet allocation, retention, release, resize
- [src/host.zig](../src/host.zig)
  host lifecycle, peers, event loop, queueing, resend, dispatch
- [src/protocol.zig](../src/protocol.zig)
  fragments, incoming and outgoing command metadata, payload parsers
- [src/wire.zig](../src/wire.zig)
  wire header layout and command serialization helpers
- [src/compression.zig](../src/compression.zig)
  Zig range coder compression
- [src/checksum.zig](../src/checksum.zig)
  CRC32 support
- [src/transport.zig](../src/transport.zig)
  transport abstraction and mock transport
- [src/transport/unix.zig](../src/transport/unix.zig)
  Unix UDP backend
- [src/transport/windows.zig](../src/transport/windows.zig)
  Windows UDP backend

## Send Path

High-level send flow:

1. `Peer.send()` receives a packet and channel id
2. packet size and channel rules are validated
3. fragmentation is planned if the payload is too large for the current MTU
4. outgoing commands are queued on the peer
5. `Host.flush()` assigns sequence numbers and writes command frames
6. optional compression is applied
7. optional checksum is written
8. the transport sends the datagram

## Receive Path

High-level receive flow:

1. `Host.service()` reads one datagram from the transport
2. the protocol header is parsed
3. checksum and Growtopia integrity validation run if enabled
4. payload is decompressed if the compressed flag is set
5. command payload is parsed
6. reliable and unreliable commands are inserted into per-channel queues
7. fragments are assembled when needed
8. ready commands become `Event.receive`

## Reliability Model

The reliability path in [src/host.zig](../src/host.zig) tracks:

- sent reliable commands
- acknowledgement queue
- resend timeouts
- round-trip time updates
- packet throttle updates
- ping generation
- disconnect timeout progression

## Incoming Ordering

Each channel maintains separate pending queues for:

- reliable commands
- unreliable commands
- fragment assemblies

Reliable traffic only dispatches when the next expected sequence number is available.

Unreliable traffic is gated by the current reliable sequence state so delivery stays compatible with ENet-style channel rules.

## Transport Separation

The transport layer is hidden behind [src/transport.zig](../src/transport.zig).

That makes it possible to:

- run unit tests with `MockTransport`
- keep socket code separate from protocol logic
- support Unix and Windows backends without changing protocol code

## Compression And Checksum

Compression and checksum are opt-in through `HostConfig`.

- Compression uses callbacks from `CompressionCallbacks`
- The built-in Zig range coder can provide those callbacks
- Checksum uses a `ChecksumFn`
- CRC32 is provided in [src/checksum.zig](../src/checksum.zig)

## Compatibility Layer

[src/compat.zig](../src/compat.zig) exposes a small ENet-style wrapper around the Zig API. It is intentionally thin and should be treated as a convenience surface, not as a full C ABI replacement.
