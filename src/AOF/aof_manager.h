#pragma once

#include <fstream>
#include "../config.h"
#include "../replication_manager.h"
#include "../RESP/resp_parser.h"
#include "../RESP/resp_serializer.h"
#include "../store.h"

using namespace std;

class AOFManager {
private:
    Config &config;
    RESPSerializer &serializer;
    ofstream aofStream;
    bool enabled = false;

public:
    AOFManager(Config &config, RESPSerializer &serializer);
    void initialize();
    void append(const RESPArray &cmd);
    void replay(Store &store, ReplicationManager &replication);

private:
    string getActiveAofFileName();
};