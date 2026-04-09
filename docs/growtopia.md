# Growtopia Notes

## Purpose

This project is aimed mainly at Growtopia private server development, so Growtopia-specific protocol handling is a first-class part of the design instead of an afterthought.

## Protocol Flavors

Defined in [src/config.zig](../src/config.zig):

- `.vanilla`
- `.growtopia_client`
- `.growtopia_server`

The most important one for this project is `.growtopia_server`.

## Growtopia Server Header

The Growtopia server flavor uses the extended header defined in [src/wire.zig](../src/wire.zig):

- `NewProtocolHeader`
- `new_protocol_header_size`

This extended header includes:

- integrity values
- peer id and session bits
- optional sent time

## Integrity Validation

Receive-side Growtopia integrity validation is handled in [src/host.zig](../src/host.zig).

Current behavior:

- integrity checks apply when the host uses `.growtopia_server`
- validation is especially important before a peer is fully connected
- the peer nonce is tracked and updated
- invalid or repeated integrity state is rejected

## When To Use Vanilla

Use `.vanilla` when:

- you want simple local testing
- you are not dealing with Growtopia server traffic
- you want to compare ordinary ENet-style behavior

The example server and client currently use `.vanilla` so they are easy to run locally.

## When To Use Growtopia Server Flavor

Use `.growtopia_server` when:

- you are implementing a Growtopia private server
- you need the custom server-side header behavior
- you need Growtopia integrity checking during connection setup

Example:

```zig
const host = try zigenet.Host.withTransport(allocator, .{
    .address = zigenet.Address.any(17091),
    .peer_limit = 32,
    .channel_limit = 2,
    .protocol_flavor = .growtopia_server,
}, transport);
```

## Related Files

- [src/config.zig](../src/config.zig)
- [src/wire.zig](../src/wire.zig)
- [src/host.zig](../src/host.zig)
