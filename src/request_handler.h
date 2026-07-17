#pragma once
#include "./AOF/aof_manager.h"
#include "RESP/resp_parser.h"
#include "RESP/resp_serializer.h"
#include "replication_manager.h"
#include "store.h"
#include "config.h"
#include <unordered_map>

struct ClientState {
    bool inTransaction = false;
    vector<RESPArray> queuedCommands;
    unordered_map<string, uint64_t> watchedKeys;
};

void toUpper(string &s);
bool shouldReplicate(const string &cmd);

class RequestHandler{
private:
    Store &store;
    Config &config;
    int clientFd;
    AOFManager &aof;
    ReplicationManager &replication;
    bool replaying = false;

public:
    RequestHandler(Store &store, Config &config, ReplicationManager &replication, AOFManager &aof, int fd, bool replaying = false);
    RESPValue handle(const RESPValue &req);
    ClientState state;

private:
    RESPValue executeCommand(const string &cmd, const RESPArray &arr);

    RESPValue handlePing();
    RESPValue handleEcho(const RESPArray &arr);
    RESPValue handleSet(const RESPArray &arr);
    RESPValue handleGet(const RESPArray &arr);
    RESPValue handleRpush(const RESPArray &arr);
    RESPValue handleLpush(const RESPArray &arr);
    RESPValue handleLrange(const RESPArray &arr);
    RESPValue handleLlen(const RESPArray &arr);
    RESPValue handleLpop(const RESPArray &arr);
    RESPValue handleBlpop(const RESPArray &arr);

    RESPValue handleType(const RESPArray &arr);
    RESPValue handleXadd(const RESPArray &arr);
    RESPValue handleXrange(const RESPArray &arr);
    RESPValue handleXread(const RESPArray &arr);
    RESPValue handleIncr(const RESPArray &arr);
    RESPValue handleExec();

    RESPValue handleWatch(const RESPArray &arr);
    RESPValue handleUnwatch(const RESPArray &arr);

    RESPValue handleInfo(const RESPArray &arr);
    RESPValue handleReplConf(const RESPArray &arr);
    RESPValue handlePsync(const RESPArray &arr);
    RESPValue handleWait(const RESPArray &arr);

    RESPValue handleConfig(const RESPArray &arr);
    RESPValue handleKeys(const RESPArray &arr);
};