# API Reference

## Root Exports

The package root is [src/root.zig](../src/root.zig).

Main exports:

- `Address`
- `Host`
- `Peer`
- `Event`
- `Packet`
- `HostConfig`
- `transport`
- `protocol`
- `wire`
- `compat`
- `compression`
- `checksum`

## Address

Defined in [src/address.zig](../src/address.zig).

Useful functions:

- `Address.any(port)`
- `Address.broadcast(port)`
- `Address.fromIpv4Octets(parts, port)`
- `octets()`
- `eql()`
- `toNetAddress()`
- `fromNetAddress()`

## Host

Defined in [src/host.zig](../src/host.zig).

Main functions:

- `Host.init(allocator, config)`
  create a host without transport
- `Host.withTransport(allocator, config, transport)`
  create a host with transport attached
- `Host.connect(address, channel_count, data)`
  create an outgoing peer and queue a connect command
- `Host.broadcast(channel_id, packet)`
  send a packet to all connected peers
- `Host.flush()`
  send queued traffic immediately
- `Host.service(timeout_ms)`
  drive network I/O and return one event if available
- `Host.deinit()`
  release host resources

## Peer

Defined in [src/host.zig](../src/host.zig).

Main functions:

- `Peer.send(channel_id, packet)`
  queue packet send
- `Peer.disconnect(data)`
  queue disconnect
- `Peer.configureThrottle(interval, acceleration, deceleration)`
  update throttle values
- `Peer.setTimeout(limit, minimum, maximum)`
  update timeout values

## Event

Defined in [src/host.zig](../src/host.zig).

Fields:

- `type`
- `peer`
- `channel_id`
- `data`
- `packet`

Event types come from [src/constants.zig](../src/constants.zig):

- `.none`
- `.connect`
- `.disconnect`
- `.receive`

## Packet

Defined in [src/packet.zig](../src/packet.zig).

Main functions:

- `Packet.create(allocator, initial_data, data_len, flags)`
- `Packet.wrapBorrowed(allocator, data, flags)`
- `retain()`
- `release()`
- `resize()`
- `destroy()`

Ownership notes:

- packets use explicit retain and release
- queued sends retain packet references
- received packets must be released by the caller after use

## HostConfig

Defined in [src/config.zig](../src/config.zig).

Important fields:

- `address`
- `peer_limit`
- `channel_limit`
- `bandwidth`
- `mtu`
- `maximum_packet_size`
- `maximum_waiting_data`
- `using_new_packet`
- `using_new_packet_for_server`
- `checksum_fn`
- `compression`

## Transport

Defined in [src/transport.zig](../src/transport.zig).

Main pieces:

- `Transport`
- `ReceiveResult`
- `MockTransport`
- `transport.unix.UdpSocket`
- `transport.windows.UdpSocket`

Unix backend:

- [src/transport/unix.zig](../src/transport/unix.zig)

Windows backend:

- [src/transport/windows.zig](../src/transport/windows.zig)

## Compression

Defined in [src/compression.zig](../src/compression.zig).

Main type:

- `compression.RangeCoder`

Main functions:

- `RangeCoder.init()`
- `RangeCoder.initWithAllocator(allocator)`
- `RangeCoder.deinit()`
- `RangeCoder.callbacks()`

`callbacks()` returns a `CompressionCallbacks` value that can be assigned to `HostConfig.compression`.

## Wire Helpers

Defined in [src/wire.zig](../src/wire.zig).

Useful functions:

- `commandSize()`
- `headerPrefixLen()`
- `headerLen()`
- `encodeHeader()`
- `parseHeader()`
- `appendU16()`
- `appendU32()`
- `appendCommandHeader()`

## Compatibility Layer

Defined in [src/compat.zig](../src/compat.zig).

Main functions:

- `enet_host_create()`
- `enet_host_connect()`
- `enet_host_service()`
- `enet_host_flush()`
- `enet_packet_create()`

This layer is useful if you want ENet-style naming while still using the Zig implementation underneath.
