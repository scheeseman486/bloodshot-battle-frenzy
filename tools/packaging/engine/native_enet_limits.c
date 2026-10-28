/* Build-time adversarial tests against the exact pinned engine ENet sources.
 * No sockets, secret material, original-game fixtures or huge allocations.
 * Build with -DUNIX_ENABLED -ffunction-sections and --gc-sections. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "enet/enet.h"
static size_t live_bytes, peak_bytes;
void *enet_malloc(size_t size) {
    size_t *allocation = malloc(sizeof(size_t) + size);
    assert(allocation);
    *allocation = size;
    live_bytes += size;
    if (live_bytes > peak_bytes) peak_bytes = live_bytes;
    return allocation + 1;
}
void enet_free(void *value) {
    if (value) {
        size_t *allocation = ((size_t *)value) - 1;
        live_bytes -= *allocation;
        free(allocation);
    }
}
/* Static handlers are intentionally included so forged native headers reach
 * the real pre-allocation guards, without needing an attacker UDP sender. */
#include "peer.c"
#include "protocol.c"
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #value); return 1; } } while (0)
int main(void) {
    ENetHost host = {0};
    ENetPeer peer = {0};
    host.maximumPacketSize = ENET_HOST_DEFAULT_MAXIMUM_PACKET_SIZE;
    host.maximumWaitingData = ENET_HOST_DEFAULT_MAXIMUM_WAITING_DATA;
    enet_list_clear(&host.dispatchQueue);
    peer.host = &host;
    peer.state = ENET_PEER_STATE_CONNECTED;
    peer.channelCount = 1;
    peer.channels = enet_malloc(sizeof(ENetChannel));
    memset(peer.channels, 0, sizeof(ENetChannel));
    enet_list_clear(&peer.channels->incomingReliableCommands);
    enet_list_clear(&peer.channels->incomingUnreliableCommands);
    enet_list_clear(&peer.acknowledgements);
    enet_list_clear(&peer.sentReliableCommands);
    enet_list_clear(&peer.outgoingCommands);
    enet_list_clear(&peer.outgoingSendReliableCommands);
    enet_list_clear(&peer.dispatchedCommands);
    unsigned char buffer[sizeof(ENetProtocol) + 1] = {0};
    ENetProtocol command = {0};
    command.header.channelID = 0;
    command.sendFragment.header.command = ENET_PROTOCOL_COMMAND_SEND_UNRELIABLE_FRAGMENT;
    command.sendFragment.startSequenceNumber = ENET_HOST_TO_NET_16(1);
    command.sendFragment.fragmentCount = ENET_HOST_TO_NET_32(2048);
    command.sendFragment.totalLength = ENET_HOST_TO_NET_32(1);
    command.sendFragment.dataLength = ENET_HOST_TO_NET_16(1);
    host.receivedData = buffer;
    host.receivedDataLength = sizeof(buffer);
    enet_uint8 *cursor = buffer + sizeof(ENetProtocolSendFragment);
    size_t before = live_bytes;
    CHECK(enet_protocol_handle_send_unreliable_fragment(&host, &peer, &command, &cursor) == -1);
    CHECK(live_bytes == before);
    CHECK(host.maximumPacketSize == 2048 && host.maximumWaitingData == 256 * 1024);
    command.header.command = ENET_PROTOCOL_COMMAND_SEND_RELIABLE;
    unsigned int accepted = 0;
    for (unsigned int index = 1; index < 4096; ++index) {
        command.header.reliableSequenceNumber = index;
        if (!enet_peer_queue_incoming_command(&peer, &command, NULL, 0, ENET_PACKET_FLAG_RELIABLE, 0)) break;
        ++accepted;
        CHECK(peer.totalWaitingData <= host.maximumWaitingData);
        CHECK(live_bytes <= host.maximumWaitingData + sizeof(ENetChannel));
    }
    CHECK(accepted == host.maximumWaitingData / 256);
    ENetPacket *packet;
    while ((packet = enet_peer_receive(&peer, NULL))) enet_packet_destroy(packet);
    CHECK(peer.totalWaitingData == 0);
    command.header.reliableSequenceNumber = peer.channels->incomingReliableSequenceNumber + 2;
    CHECK(enet_peer_queue_incoming_command(&peer, &command, NULL, 2049, ENET_PACKET_FLAG_RELIABLE, 0) == NULL);
    CHECK(enet_peer_queue_incoming_command(&peer, &command, NULL, 2048, ENET_PACKET_FLAG_RELIABLE, 0) != NULL);
    CHECK(peer.totalWaitingData == 2048 + 256);
    enet_peer_reset_queues(&peer);
    CHECK(peer.totalWaitingData == 0);
    CHECK(live_bytes == 0);
    printf("{\"native_limits\":true,\"packet\":2048,\"waiting\":262144,\"zero_byte_limit\":%u,\"peak_allocation\":%zu,\"released\":true}\n", accepted, peak_bytes);
    return 0;
}
