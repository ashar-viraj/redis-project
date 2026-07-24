#pragma once

#include <vector>
#include "RESP/resp_parser.h"
#include "RESP/resp_serializer.h"

struct Replica {
    int clientFd;
    long long acknowledgedOffset = 0;
};

class ReplicationManager {
    vector<Replica> replicaSockets;
    RESPSerializer &serializer;
    long long processedOffset = 0;

    long long masterOffset = 0;
    bool pendingWrites = false;

public:
    ReplicationManager(RESPSerializer &serializer);

    void addReplica(int fd);
    void removeReplica(int fd);
    void propagate(const RESPArray &arr);
    long long getProcessedOffset() const;
    void addProcessedOffset(long long bytes);
    long long getReplicaCount();
    long long getMasterOffset() const;

    void updateAcknowledgeOffset(int clientFd, long long offset);
    bool hasPendingWrites() const;
    long long requestAcks();
    int countAcked(long long targetOffset);
    bool isReplicaConnection(int fd);
};
