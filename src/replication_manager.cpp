#include "replication_manager.h"
#include "RESP/resp_serializer.h"
#include "network_utils.h"

#include <iostream>
#include <chrono>

using namespace std;

ReplicationManager::ReplicationManager(RESPSerializer &serializer) : serializer(serializer){ }

void ReplicationManager::addReplica(int clientFd) {
    lock_guard<mutex> lock(replicaMtx);
    Replica replica;
    replica.clientFd = clientFd;
    replicaSockets.push_back(replica);
}

void ReplicationManager::removeReplica(int clientFd) {
    lock_guard<mutex> lock(replicaMtx);
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
    cout << "Propagating to " << replicaSockets.size() << " clients\n";
    const string bytes = serializer.serialize({arr, '*'});

    vector<int> fds;
    {
        lock_guard<mutex> lock(replicaMtx);
        masterOffset += bytes.size();
        cout << "masterOffset = " << masterOffset << endl;
        pendingWrites = true;
        for(auto &replica : replicaSockets)
            fds.push_back(replica.clientFd);
    }

    for(auto &fd : fds) {
        cout << "Sending to " << fd << endl;
        send_msg(bytes, fd);
    }
}

void ReplicationManager::updateAcknowledgeOffset(int clientFd, long long offset) {
    cout << clientFd << " ACK " << offset << endl;
    {
        lock_guard<mutex> lock(replicaMtx);
        for(auto &replica : replicaSockets) {
            if(replica.clientFd == clientFd) {
                replica.acknowledgedOffset = offset;
                break;
            }
        }
    }
    ackCv.notify_all();
}

int ReplicationManager::waitForAcks(int numReplicas, long long timeoutMs) {
    cout << "Entered waitForAcks()" << endl;
    long long targetOffset;
    vector<int> fds;
    {
        lock_guard<mutex> lock(replicaMtx);
        if(!pendingWrites)
            return (int)replicaSockets.size();
        targetOffset = masterOffset;
        pendingWrites = false;
        for(auto &replica : replicaSockets)
            fds.push_back(replica.clientFd);
    }

    if(targetOffset == 0) {
        lock_guard<mutex> lock(replicaMtx);
        return (int)replicaSockets.size();
    }

    cout << "Sending GETACK" << endl;

    RESPArray getack = {
        RESPValue{"REPLCONF", '$'},
        RESPValue{"GETACK", '$'},
        RESPValue{"*", '$'}
    };

    const string bytes = serializer.serialize({getack, '*'});

    {
        lock_guard<mutex> lock(replicaMtx);
        masterOffset += bytes.size();
    }

    for(auto fd : fds)
        send_msg(bytes, fd);

    auto countAcked = [&]() {
        int count = 0;
        for(auto &replica : replicaSockets)
            if(replica.acknowledgedOffset >= targetOffset)
                count++;
        return count;
    };

    unique_lock<mutex> lock(replicaMtx);

    auto deadline = chrono::steady_clock::now() + chrono::milliseconds(timeoutMs);

    int acked = countAcked();

    while(acked < numReplicas && chrono::steady_clock::now() < deadline) {
        ackCv.wait_until(lock, deadline);
        acked = countAcked();
    }

    return acked;
}

long long ReplicationManager::getProcessedOffset() const {
    return processedOffset;
}

void ReplicationManager::addProcessedOffset(long long bytes) {
    processedOffset += bytes;
}

long long ReplicationManager::getReplicaCount() {
    lock_guard<mutex> lock(replicaMtx);
    return replicaSockets.size();
}

bool ReplicationManager::isReplicaConnection(int fd) {
    lock_guard<mutex> lock(replicaMtx);
    for(auto &replica : replicaSockets)
        if(replica.clientFd == fd)
            return true;
    return false;
}
