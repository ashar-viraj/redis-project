#pragma once

#include <vector>
#include "RESP/resp_parser.h"
#include "RESP/resp_serializer.h"

struct Replica {
    int clientFd;
};

class ReplicationManager {
    vector<Replica> replicaSockets;
    RESPSerializer serializer;

public:
    ReplicationManager(RESPSerializer &serializer);

    void addReplica(int fd);
    void propagate(const RESPArray &arr);
};