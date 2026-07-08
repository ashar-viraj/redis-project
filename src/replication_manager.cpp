#include "replication_manager.h"
#include "RESP/resp_serializer.h"
#include "network_utils.h"

#include <iostream>

using namespace std;

ReplicationManager::ReplicationManager(RESPSerializer &serializer) : serializer(serializer){ }

void ReplicationManager::addReplica(int clientFd) {
    Replica replica;
    replica.clientFd = clientFd;
    replicaSockets.push_back(replica);

    cout << "Added a preplica and size is " << replicaSockets.size() << endl;
}

void ReplicationManager::propagate(const RESPArray &arr) {
    cout << "Propagating to " << replicaSockets.size() << " clients\n";
    const string bytes = serializer.serialize({arr, '*'});

    for(auto &replica : replicaSockets) {
        cout << "Sending to " << replica.clientFd << endl;
        cout << bytes << endl;
        send_msg(bytes, replica.clientFd);
    }
}

long long ReplicationManager::getProcessedOffset() const {
    return processedOffset;
}

void ReplicationManager::addProcessedOffset(long long bytes) {
    processedOffset += bytes;
}