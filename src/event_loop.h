#pragma once

#include "./AOF/aof_manager.h"
#include "config.h"
#include "replication_manager.h"
#include "request_handler.h"
#include "RESP/resp_parser.h"
#include "RESP/resp_serializer.h"
#include "store.h"

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

class EventLoop {
private:
    struct ClientConnection {
        int fd = -1;
        string inputBuffer;
        string outputBuffer;
        size_t outputOffset = 0;
        shared_ptr<RequestHandler> handler;
        bool blocked = false;
        bool closeAfterWrite = false;
    };

    struct ExternalOutput {
        int fd = -1;
        string bytes;
        bool unblockClient = false;
    };

    int serverFd;
    int epollFd = -1;
    int wakeFd = -1;

    Store &store;
    RESPSerializer &serializer;
    ReplicationManager &replication;
    AOFManager &aof;
    Config &config;
    RESPParser parser;

    unordered_map<int, ClientConnection> clients;

    mutex managedFdsMutex;
    unordered_set<int> managedFds;
    unordered_set<int> retiredManagedFds;

    mutex externalOutputsMutex;
    vector<ExternalOutput> externalOutputs;

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
    bool queueOutputFromAnyThread(int fd, const string &bytes);
    void enqueueExternalOutput(int fd, const string &bytes, bool unblockClient);
    void drainExternalOutputs();
    void wake();
    void drainWakeFd();

    void registerManagedFd(int fd);
    void unregisterManagedFd(int fd);
    bool isManagedFd(int fd);
    bool isRetiredManagedFd(int fd);

    bool commandShouldRunOffLoop(ClientConnection &client, const RESPValue &req, const string &cmd);
    void startOffLoopCommand(ClientConnection &client, const RESPValue &req);
    string executeOffLoopCommand(shared_ptr<RequestHandler> handler, const RESPValue &req);
    string extractCommandName(const RESPValue &req);
};
