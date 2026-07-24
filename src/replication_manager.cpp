#include "replication_manager.h"
#include "RESP/resp_serializer.h"
#include "network_utils.h"

#include <algorithm>
#include <iostream>

using namespace std;

ReplicationManager::ReplicationManager(RESPSerializer &serializer) : serializer(serializer){ }

void ReplicationManager::addReplica(int clientFd) {
    Replica replica;
    replica.clientFd = clientFd;
    replicaSockets.push_back(replica);
}

void ReplicationManager::removeReplica(int clientFd) {
    replicaSockets.erase(
        remove_if(replicaSockets.begin(), replicaSockets.end(),
            [clientFd](const Replica &replica) {
                return replica.clientFd == clientFd;
            }
        ),
        replicaSockets.end()
    );
}

void ReplicationManager::propagate(const RESPArray &arr) {
    const string bytes = serializer.serialize({arr, '*'});

    masterOffset += bytes.size();
    pendingWrites = true;

    for(auto &replica : replicaSockets)
        send_msg(bytes, replica.clientFd);
}

void ReplicationManager::updateAcknowledgeOffset(int clientFd, long long offset) {
    for(auto &replica : replicaSockets) {
        if(replica.clientFd == clientFd) {
            replica.acknowledgedOffset = offset;
            break;
        }
    }
}

bool ReplicationManager::hasPendingWrites() const {
    return pendingWrites;
}

long long ReplicationManager::requestAcks() {
    long long targetOffset = masterOffset;
    pendingWrites = false;

    if(targetOffset == 0)
        return targetOffset;

    RESPArray getack = {
        RESPValue{"REPLCONF", '$'},
        RESPValue{"GETACK", '$'},
        RESPValue{"*", '$'}
    };

    const string bytes = serializer.serialize({getack, '*'});
    masterOffset += bytes.size();

    for(auto &replica : replicaSockets)
        send_msg(bytes, replica.clientFd);

    return targetOffset;
}

int ReplicationManager::countAcked(long long targetOffset) {
    int count = 0;
    for(auto &replica : replicaSockets)
        if(replica.acknowledgedOffset >= targetOffset)
            count++;
    return count;
}

long long ReplicationManager::getProcessedOffset() const {
    return processedOffset;
}

void ReplicationManager::addProcessedOffset(long long bytes) {
    processedOffset += bytes;
}

long long ReplicationManager::getReplicaCount() {
    return replicaSockets.size();
}

long long ReplicationManager::getMasterOffset() const {
    return masterOffset;
}

bool ReplicationManager::isReplicaConnection(int fd) {
    for(auto &replica : replicaSockets)
        if(replica.clientFd == fd)
            return true;
    return false;
}
