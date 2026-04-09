# Growtopia Notes

## Purpose

This project is aimed mainly at Growtopia private server development, so Growtopia-specific protocol handling is a first-class part of the design instead of an afterthought.

## HostConfig Flags

Defined in [src/config.zig](../src/config.zig):

- `using_new_packet`
- `using_new_packet_for_server`

For Growtopia private server work, the most important flag is `using_new_packet_for_server`.

## New Packet Header

When `using_new_packet` is enabled, outgoing packets use the extended header defined in [src/wire.zig](../src/wire.zig):

- `NewProtocolHeader`
- `new_protocol_header_size`

This extended header includes:

- integrity values
- peer id and session bits
- optional sent time

## Integrity Validation

Receive-side Growtopia integrity validation is handled in [src/host.zig](../src/host.zig).

Current behavior:

- integrity checks apply when `using_new_packet_for_server` is enabled
- validation is especially important before a peer is fully connected
- the peer nonce is tracked and updated
- invalid or repeated integrity state is rejected

## When To Leave Both Disabled

Use `using_new_packet = false` and `using_new_packet_for_server = false` when:

- you want simple local testing
- you are not dealing with Growtopia server traffic
- you want to compare ordinary ENet-style behavior

The example server and client currently leave both flags disabled so they are easy to run locally.

## When To Enable Growtopia Flags

Use `using_new_packet_for_server = true` when:

- you are implementing a Growtopia private server
- you need the custom server-side parsing and integrity behavior
- you need Growtopia integrity checking during connection setup

Use `using_new_packet = true` when:

- you want this host to send the newer packet header format
- you are matching older GTEnet-style client behavior
- you want fragmentation sizing and outgoing header encoding to follow the new packet layout

You can enable one or both flags depending on the behavior you want.

Example:

```zig
const host = try zigenet.Host.withTransport(allocator, .{
    .address = zigenet.Address.any(17091),
    .peer_limit = 32,
    .channel_limit = 2,
    .using_new_packet = true,
    .using_new_packet_for_server = true,
}, transport);
```

## Related Files

- [src/config.zig](../src/config.zig)
- [src/wire.zig](../src/wire.zig)
- [src/host.zig](../src/host.zig)
