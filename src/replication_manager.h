#pragma once

#include <vector>
#include <mutex>
#include <condition_variable>
#include "RESP/resp_parser.h"
#include "RESP/resp_serializer.h"

struct Replica {
    int clientFd;
    long long acknowledgedOffset = 0;
};

class ReplicationManager {
    vector<Replica> replicaSockets;
    RESPSerializer serializer;
    long long processedOffset = 0;

    long long masterOffset = 0;
    bool pendingWrites = false;
    mutex replicaMtx;
    condition_variable ackCv;

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
    int waitForAcks(int numReplicas, long long timeoutMs);
    bool isReplicaConnection(int fd);
};