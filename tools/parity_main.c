#include <stdlib.h>
#include <string.h>
#include <enet/enet.h>

void *enet_malloc(size_t size) {
    return malloc(size);
}

void enet_free(void *memory) {
    free(memory);
}

unsigned int parity_crc32(const char *input) {
    ENetBuffer buffer;
    buffer.data = (void *)input;
    buffer.dataLength = strlen(input);
    return enet_crc32(&buffer, 1);
}

size_t parity_connect_fixture(unsigned char *out, size_t out_len) {
    ENetProtocolConnect command;
    if (out_len < sizeof(command)) {
        return 0;
    }

    memset(&command, 0, sizeof(command));
    command.header.command = ENET_PROTOCOL_COMMAND_CONNECT | ENET_PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE;
    command.header.channelID = 0xFF;
    command.header.reliableSequenceNumber = ENET_HOST_TO_NET_16(1);
    command.outgoingPeerID = ENET_HOST_TO_NET_16(7);
    command.incomingSessionID = 1;
    command.outgoingSessionID = 2;
    command.mtu = ENET_HOST_TO_NET_32(1392);
    command.windowSize = ENET_HOST_TO_NET_32(32768);
    command.channelCount = ENET_HOST_TO_NET_32(2);
    command.incomingBandwidth = ENET_HOST_TO_NET_32(100000);
    command.outgoingBandwidth = ENET_HOST_TO_NET_32(200000);
    command.packetThrottleInterval = ENET_HOST_TO_NET_32(5000);
    command.packetThrottleAcceleration = ENET_HOST_TO_NET_32(2);
    command.packetThrottleDeceleration = ENET_HOST_TO_NET_32(2);
    command.connectID = ENET_HOST_TO_NET_32(0x11223344);
    command.data = ENET_HOST_TO_NET_32(0x55667788);

    memcpy(out, &command, sizeof(command));
    return sizeof(command);
}

size_t parity_verify_connect_fixture(unsigned char *out, size_t out_len) {
    ENetProtocolVerifyConnect command;
    if (out_len < sizeof(command)) {
        return 0;
    }

    memset(&command, 0, sizeof(command));
    command.header.command = ENET_PROTOCOL_COMMAND_VERIFY_CONNECT | ENET_PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE;
    command.header.channelID = 0xFF;
    command.header.reliableSequenceNumber = ENET_HOST_TO_NET_16(3);
    command.outgoingPeerID = ENET_HOST_TO_NET_16(9);
    command.incomingSessionID = 2;
    command.outgoingSessionID = 1;
    command.mtu = ENET_HOST_TO_NET_32(1392);
    command.windowSize = ENET_HOST_TO_NET_32(32768);
    command.channelCount = ENET_HOST_TO_NET_32(2);
    command.incomingBandwidth = ENET_HOST_TO_NET_32(120000);
    command.outgoingBandwidth = ENET_HOST_TO_NET_32(240000);
    command.packetThrottleInterval = ENET_HOST_TO_NET_32(5000);
    command.packetThrottleAcceleration = ENET_HOST_TO_NET_32(2);
    command.packetThrottleDeceleration = ENET_HOST_TO_NET_32(2);
    command.connectID = ENET_HOST_TO_NET_32(0xAABBCCDD);

    memcpy(out, &command, sizeof(command));
    return sizeof(command);
}

void parity_sizes(size_t *ack, size_t *connect, size_t *verify_connect, size_t *disconnect, size_t *ping, size_t *send_reliable, size_t *send_unreliable, size_t *send_unsequenced, size_t *send_fragment) {
    *ack = sizeof(ENetProtocolAcknowledge);
    *connect = sizeof(ENetProtocolConnect);
    *verify_connect = sizeof(ENetProtocolVerifyConnect);
    *disconnect = sizeof(ENetProtocolDisconnect);
    *ping = sizeof(ENetProtocolPing);
    *send_reliable = sizeof(ENetProtocolSendReliable);
    *send_unreliable = sizeof(ENetProtocolSendUnreliable);
    *send_unsequenced = sizeof(ENetProtocolSendUnsequenced);
    *send_fragment = sizeof(ENetProtocolSendFragment);
}
