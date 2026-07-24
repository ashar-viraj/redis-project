#pragma once

#include "./AOF/aof_manager.h"
#include "config.h"
#include "replication_manager.h"
#include "request_handler.h"
#include "RESP/resp_parser.h"
#include "RESP/resp_serializer.h"
#include "store.h"

#include <chrono>
#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

class EventLoop {
private:
    enum class ConnectionRole { Client, MasterLink };
    enum class BlockReason { None, BLPOP, XREAD, WAIT };
    enum class BlockingAttemptResult { NotApplicable, Handled, Parked };

    struct ClientConnection {
        int fd = -1;
        string inputBuffer;
        string outputBuffer;
        size_t outputOffset = 0;
        shared_ptr<RequestHandler> handler;
        ConnectionRole role = ConnectionRole::Client;

        bool blocked = false;
        BlockReason reason = BlockReason::None;
        RESPArray blockedRequestArr;                          // original command, for BLPOP finalize/replication
        string blockedKey;                                    // BLPOP: key it's parked on
        vector<pair<string, string>> blockedResolvedStreams;  // XREAD: resolved stream/id pairs
        chrono::steady_clock::time_point blockDeadline;
        bool blockHasTimeout = false;

        bool closeAfterWrite = false;
    };

    struct PendingWait {
        int fd;
        int numReplicas;
        long long targetOffset;
    };

    int serverFd;
    int epollFd = -1;

    Store &store;
    RESPSerializer &serializer;
    ReplicationManager &replication;
    AOFManager &aof;
    Config &config;
    RESPParser parser;

    unordered_map<int, ClientConnection> clients;

    unordered_map<string, deque<int>> blockedListClients;
    unordered_map<string, deque<int>> blockedStreamClients;
    vector<PendingWait> blockedWaitClients;

    thread::id loopThreadId;

public:
    EventLoop(int serverFd,
              Store &store,
              RESPSerializer &serializer,
              ReplicationManager &replication,
              AOFManager &aof,
              Config &config);
    ~EventLoop();

    void run();

    // Hands off an already-handshaken master connection (see connectToMaster()
    // in main.cpp) to the loop. Any bytes that arrived bundled right after the
    // handshake are passed in `pendingBytes` and treated as already-buffered
    // input.
    void adoptMasterConnection(int fd, string &&pendingBytes);

private:
    bool setNonBlocking(int fd);
    uint32_t clientEvents(const ClientConnection &client);
    void addFd(int fd, uint32_t events);
    void modifyFd(int fd, uint32_t events);
    void deleteFd(int fd);

    void acceptNewClients();
    void readFromClient(int fd);
    void writeToClient(int fd);
    void consumeClientCommands(ClientConnection &client);
    void removeClient(int fd);

    bool queueOutput(int fd, const string &bytes);
    bool queueOutput(ClientConnection &client, const string &bytes);

    string extractCommandName(const RESPValue &req);
    bool isBlockingXread(const RESPValue &req);

    BlockingAttemptResult attemptBlockingCommand(ClientConnection &client, const RESPValue &req, const string &cmd);
    void parkClient(ClientConnection &client, BlockReason reason, const RESPArray &arr, bool hasTimeout, long long timeoutMs);
    void unblockClient(ClientConnection &client, const string &bytes);

    void runPostCommandHooks(const string &cmd, const RESPValue &req, const string &response);
    void wakeBlockedListClients(const string &key);
    void wakeBlockedStreamClients(const string &key);
    void checkBlockedWaits();

    void removeListClientRegistration(int fd, const string &key);
    void removeStreamClientRegistrations(int fd, const vector<pair<string, string>> &resolvedStreams);

    int computeNextTimeoutMs();
    void checkBlockedTimeouts();
};
