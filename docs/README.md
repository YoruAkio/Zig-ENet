# Zig ENet Documentation

This folder contains project documentation for the Zig ENet rewrite used mainly for Growtopia private server development.

## Documents

- [Getting Started](getting-started.md)
  Build, test, run, and try the examples
- [Architecture](architecture.md)
  Internal layout and data flow
- [API Reference](api.md)
  Main public types and functions
- [Growtopia Notes](growtopia.md)
  Protocol flavor behavior and Growtopia-specific details

## Scope

The project is a Zig-first rewrite of ENet-style networking. The shipped library, tools, tests, and examples build from Zig code.

## Main Goals

- Provide a Zig-native ENet-style runtime
- Keep the wire format and behavior practical for Growtopia private server work
- Preserve a usable ENet-style compatibility layer where helpful
- Keep protocol, memory, and transport code explicit and testable

## Main Entry Points

- [src/root.zig](../src/root.zig)
  Package exports
- [src/host.zig](../src/host.zig)
  Host, peer, event loop, reliability, resend, queueing
- [src/protocol.zig](../src/protocol.zig)
  Protocol helpers, fragments, connection payload parsing
- [src/wire.zig](../src/wire.zig)
  Wire structs, sizes, header encode and decode
- [src/compression.zig](../src/compression.zig)
  Zig range coder implementation

## Current Build Targets

- `zigenet`
  Static library
- `zigenet-server`
  Example server
- `zigenet-client`
  Example client
- `parity-harness`
  Small Zig utility for wire and checksum inspection
