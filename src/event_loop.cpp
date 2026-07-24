#include "event_loop.h"

#include "empty_rdb.h"
#include "network_utils.h"

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <stdexcept>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

using namespace std;

namespace {
constexpr int MAX_EVENTS = 32768;
constexpr int READ_BUFFER_SIZE = 16 * 1024;
}

EventLoop::EventLoop(int serverFd,
                     Store &store,
                     RESPSerializer &serializer,
                     ReplicationManager &replication,
                     AOFManager &aof,
                     Config &config)
    : serverFd(serverFd),
      store(store),
      serializer(serializer),
      replication(replication),
      aof(aof),
      config(config) {
    epollFd = epoll_create1(EPOLL_CLOEXEC);
    if(epollFd == -1)
        throw runtime_error("Failed to create epoll instance");

    if(!setNonBlocking(serverFd))
        throw runtime_error("Failed to make server socket non-blocking");

    addFd(serverFd, EPOLLIN);

    set_send_sink([this](int fd, const string &bytes) {
        queueOutput(fd, bytes);
    });
}

EventLoop::~EventLoop() {
    set_send_sink(nullptr);

    for(auto &[fd, _] : clients)
        close(fd);

    if(epollFd != -1)
        close(epollFd);
}

void EventLoop::run() {
    loopThreadId = this_thread::get_id();
    vector<epoll_event> events(MAX_EVENTS);

    while(true) {
        int timeoutMs = computeNextTimeoutMs();
        int ready = epoll_wait(epollFd, events.data(), MAX_EVENTS, timeoutMs);
        if(ready == -1) {
            if(errno == EINTR) {
                checkBlockedTimeouts();
                continue;
            }
            throw runtime_error(string("epoll_wait failed: ") + strerror(errno));
        }

        for(int i = 0; i < ready; i++) {
            int fd = events[i].data.fd;
            uint32_t ev = events[i].events;

            if(fd == serverFd) {
                acceptNewClients();
                continue;
            }

            if(ev & EPOLLIN)
                readFromClient(fd);

            if(clients.find(fd) == clients.end())
                continue;

            if(ev & EPOLLOUT)
                writeToClient(fd);

            if(clients.find(fd) == clients.end())
                continue;

            if(ev & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) {
                auto itr = clients.find(fd);
                if(itr == clients.end())
                    continue;

                if(itr->second.outputBuffer.empty())
                    removeClient(fd);
                else {
                    itr->second.closeAfterWrite = true;
                    modifyFd(fd, clientEvents(itr->second));
                }
            }
        }

        checkBlockedTimeouts();
    }
}

bool EventLoop::setNonBlocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if(flags == -1)
        return false;

    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1;
}

uint32_t EventLoop::clientEvents(const ClientConnection &client) {
    uint32_t events = EPOLLIN | EPOLLRDHUP;
    if(!client.outputBuffer.empty())
        events |= EPOLLOUT;
    return events;
}

void EventLoop::addFd(int fd, uint32_t events) {
    epoll_event event{};
    event.events = events;
    event.data.fd = fd;

    if(epoll_ctl(epollFd, EPOLL_CTL_ADD, fd, &event) == -1)
        throw runtime_error(string("epoll add failed: ") + strerror(errno));
}

void EventLoop::modifyFd(int fd, uint32_t events) {
    epoll_event event{};
    event.events = events;
    event.data.fd = fd;

    if(epoll_ctl(epollFd, EPOLL_CTL_MOD, fd, &event) == -1 && errno != ENOENT)
        throw runtime_error(string("epoll modify failed: ") + strerror(errno));
}

void EventLoop::deleteFd(int fd) {
    epoll_ctl(epollFd, EPOLL_CTL_DEL, fd, nullptr);
}

void EventLoop::acceptNewClients() {
    while(true) {
        sockaddr_in clientAddr{};
        socklen_t clientAddrLen = sizeof(clientAddr);

        int clientFd = accept(serverFd, reinterpret_cast<sockaddr *>(&clientAddr), &clientAddrLen);
        if(clientFd == -1) {
            if(errno == EAGAIN || errno == EWOULDBLOCK)
                break;
            if(errno == EINTR)
                continue;

            cout << "Client connection failed: " << strerror(errno) << "\n";
            break;
        }

        if(!setNonBlocking(clientFd)) {
            close(clientFd);
            continue;
        }

        ClientConnection client;
        client.fd = clientFd;
        client.handler = make_shared<RequestHandler>(
            store,
            serializer,
            config,
            replication,
            aof,
            clientFd);

        clients.emplace(clientFd, move(client));
        addFd(clientFd, EPOLLIN | EPOLLRDHUP);
    }
}

void EventLoop::readFromClient(int fd) {
    auto itr = clients.find(fd);
    if(itr == clients.end())
        return;

    ClientConnection &client = itr->second;
    char buffer[READ_BUFFER_SIZE];
    bool peerClosed = false;

    while(true) {
        ssize_t received = recv(fd, buffer, sizeof(buffer), 0);
        if(received > 0) {
            client.inputBuffer.append(buffer, static_cast<size_t>(received));

            if(!client.blocked) {
                consumeClientCommands(client);

                auto refreshed = clients.find(fd);
                if(refreshed == clients.end())
                    return;

                if(!refreshed->second.outputBuffer.empty())
                    writeToClient(fd);

                refreshed = clients.find(fd);
                if(refreshed == clients.end())
                    return;
            }

            continue;
        }

        if(received == 0) {
            peerClosed = true;
            break;
        }

        if(errno == EINTR)
            continue;

        if(errno == EAGAIN || errno == EWOULDBLOCK)
            break;

        removeClient(fd);
        return;
    }

    if(!client.blocked)
        consumeClientCommands(client);

    auto afterConsume = clients.find(fd);
    if(afterConsume == clients.end())
        return;

    if(peerClosed) {
        if(afterConsume->second.outputBuffer.empty())
            removeClient(fd);
        else {
            afterConsume->second.closeAfterWrite = true;
            modifyFd(fd, clientEvents(afterConsume->second));
        }
    }
}

void EventLoop::writeToClient(int fd) {
    auto itr = clients.find(fd);
    if(itr == clients.end())
        return;

    ClientConnection &client = itr->second;

    while(client.outputOffset < client.outputBuffer.size()) {
        ssize_t sent = send(
            fd,
            client.outputBuffer.data() + client.outputOffset,
            client.outputBuffer.size() - client.outputOffset,
            MSG_NOSIGNAL);

        if(sent > 0) {
            client.outputOffset += static_cast<size_t>(sent);
            continue;
        }

        if(sent == -1 && errno == EINTR)
            continue;

        if(sent == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
            break;

        removeClient(fd);
        return;
    }

    if(client.outputOffset == client.outputBuffer.size()) {
        client.outputBuffer.clear();
        client.outputOffset = 0;

        if(client.closeAfterWrite) {
            removeClient(fd);
            return;
        }
    }

    modifyFd(fd, clientEvents(client));
}

void EventLoop::consumeClientCommands(ClientConnection &client) {
    while(!client.inputBuffer.empty() && !client.blocked) {
        size_t bytesConsumed = 0;
        RESPValue req;

        try {
            req = parser.parse(client.inputBuffer, bytesConsumed);
        } catch(const exception &e) {
            string msg = e.what();
            if(msg == "Incomplete RESP message")
                break;

            if(client.role == ConnectionRole::Client)
                queueOutput(client, "-" + msg + "\r\n");
            else
                cout << "ERR while replicating : " << msg << endl;

            client.inputBuffer.clear();
            break;
        }

        client.inputBuffer.erase(0, bytesConsumed);

        string cmd = extractCommandName(req);

        if(client.role == ConnectionRole::MasterLink) {
            bool isGetAck = (cmd == "REPLCONF");
            if(isGetAck && holds_alternative<RESPArray>(req.value)) {
                const RESPArray &a = get<RESPArray>(req.value);
                isGetAck = a.size() >= 2 && holds_alternative<string>(a[1].value);
                if(isGetAck) {
                    string sub = get<string>(a[1].value);
                    toUpper(sub);
                    isGetAck = (sub == "GETACK");
                }
            } else {
                isGetAck = false;
            }

            string response;
            try {
                RESPValue res = client.handler->handle(req);
                response = serializer.serialize(res);
            } catch(const exception &e) {
                response = "-" + string(e.what()) + "\r\n";
            } catch(...) {
                response = "-ERR unknown error\r\n";
            }

            if(isGetAck)
                queueOutput(client, response);
            else if(!response.empty() && response[0] == '-')
                cout << "ERR while replicating : " << response << endl;

            replication.addProcessedOffset(bytesConsumed);
            runPostCommandHooks(cmd, req, response);
            continue;
        }

        bool sendRdb = (!config.isReplica && cmd == "PSYNC");

        BlockingAttemptResult attempt = attemptBlockingCommand(client, req, cmd);
        if(attempt == BlockingAttemptResult::Parked)
            break;
        if(attempt == BlockingAttemptResult::Handled)
            continue;

        string response;
        try {
            RESPValue res = client.handler->handle(req);
            response = serializer.serialize(res);
        } catch(const exception &e) {
            response = "-" + string(e.what()) + "\r\n";
        } catch(...) {
            response = "-ERR unknown error\r\n";
        }

        bool shouldReply = !(cmd != "PSYNC" && replication.isReplicaConnection(client.fd));

        if(shouldReply) {
            queueOutput(client, response);

            if(sendRdb) {
                string rdb = getEmptyRdb();
                queueOutput(client, "$" + to_string(rdb.size()) + "\r\n");
                queueOutput(client, rdb);
            }
        } else if(!response.empty()) {
            cout << "ERR while replicating : " << response << endl;
        }

        runPostCommandHooks(cmd, req, response);
    }
}

void EventLoop::removeClient(int fd) {
    auto itr = clients.find(fd);
    if(itr == clients.end())
        return;

    ClientConnection &client = itr->second;

    if(client.blocked) {
        switch(client.reason) {
            case BlockReason::BLPOP:
                removeListClientRegistration(fd, client.blockedKey);
                break;
            case BlockReason::XREAD:
                removeStreamClientRegistrations(fd, client.blockedResolvedStreams);
                break;
            case BlockReason::WAIT:
                blockedWaitClients.erase(
                    remove_if(blockedWaitClients.begin(), blockedWaitClients.end(),
                        [fd](const PendingWait &pw) { return pw.fd == fd; }),
                    blockedWaitClients.end());
                break;
            default:
                break;
        }
    }

    replication.removeReplica(fd);
    deleteFd(fd);
    close(fd);
    clients.erase(itr);
}

bool EventLoop::queueOutput(int fd, const string &bytes) {
    auto itr = clients.find(fd);
    if(itr == clients.end())
        return false;

    return queueOutput(itr->second, bytes);
}

bool EventLoop::queueOutput(ClientConnection &client, const string &bytes) {
    if(bytes.empty())
        return true;

    client.outputBuffer.append(bytes);
    modifyFd(client.fd, clientEvents(client));
    return true;
}

string EventLoop::extractCommandName(const RESPValue &req) {
    if(req.type != '*' || !holds_alternative<RESPArray>(req.value))
        return "";

    const RESPArray &arr = get<RESPArray>(req.value);
    if(arr.empty() || !holds_alternative<string>(arr[0].value))
        return "";

    string cmd = get<string>(arr[0].value);
    toUpper(cmd);
    return cmd;
}

bool EventLoop::isBlockingXread(const RESPValue &req) {
    const RESPArray &arr = get<RESPArray>(req.value);
    if(arr.size() < 2 || !holds_alternative<string>(arr[1].value))
        return false;

    string firstKeyword = get<string>(arr[1].value);
    toUpper(firstKeyword);
    return firstKeyword == "BLOCK";
}

EventLoop::BlockingAttemptResult EventLoop::attemptBlockingCommand(ClientConnection &client, const RESPValue &req, const string &cmd) {
    if(!client.handler->state.authenticated || client.handler->state.inTransaction)
        return BlockingAttemptResult::NotApplicable;

    bool isBlpop = (cmd == "BLPOP");
    bool isXreadBlock = (cmd == "XREAD") && isBlockingXread(req);
    bool isWait = (cmd == "WAIT");

    if(!isBlpop && !isXreadBlock && !isWait)
        return BlockingAttemptResult::NotApplicable;

    const RESPArray &arr = get<RESPArray>(req.value);

    if(isBlpop) {
        string key;
        double timeoutSeconds = 0;
        optional<RESPValue> res;

        try {
            res = client.handler->tryBlpop(arr, key, timeoutSeconds);
        } catch(const exception &e) {
            queueOutput(client, "-" + string(e.what()) + "\r\n");
            return BlockingAttemptResult::Handled;
        }

        if(res) {
            queueOutput(client, serializer.serialize(*res));
            return BlockingAttemptResult::Handled;
        }

        client.blockedKey = key;
        parkClient(client, BlockReason::BLPOP, arr, timeoutSeconds > 0, (long long)(timeoutSeconds * 1000));
        blockedListClients[key].push_back(client.fd);
        return BlockingAttemptResult::Parked;
    }

    if(isXreadBlock) {
        vector<pair<string, string>> resolved;
        long long timeoutMs = 0;
        optional<RESPValue> res;

        try {
            res = client.handler->tryXreadBlock(arr, resolved, timeoutMs);
        } catch(const exception &e) {
            queueOutput(client, "-" + string(e.what()) + "\r\n");
            return BlockingAttemptResult::Handled;
        }

        if(res) {
            queueOutput(client, serializer.serialize(*res));
            return BlockingAttemptResult::Handled;
        }

        client.blockedResolvedStreams = resolved;
        parkClient(client, BlockReason::XREAD, arr, timeoutMs > 0, timeoutMs);
        for(const auto &[key, _] : resolved)
            blockedStreamClients[key].push_back(client.fd);
        return BlockingAttemptResult::Parked;
    }

    // WAIT
    int numReplicas = 0;
    long long targetOffset = 0, timeoutMs = 0;
    optional<RESPValue> res;

    try {
        res = client.handler->tryWait(arr, numReplicas, targetOffset, timeoutMs);
    } catch(const exception &e) {
        queueOutput(client, "-" + string(e.what()) + "\r\n");
        return BlockingAttemptResult::Handled;
    }

    if(res) {
        queueOutput(client, serializer.serialize(*res));
        return BlockingAttemptResult::Handled;
    }

    parkClient(client, BlockReason::WAIT, arr, timeoutMs > 0, timeoutMs);
    blockedWaitClients.push_back({client.fd, numReplicas, targetOffset});
    return BlockingAttemptResult::Parked;
}

void EventLoop::parkClient(ClientConnection &client, BlockReason reason, const RESPArray &arr, bool hasTimeout, long long timeoutMs) {
    client.blocked = true;
    client.reason = reason;
    client.blockedRequestArr = arr;
    client.blockHasTimeout = hasTimeout;
    client.blockDeadline = chrono::steady_clock::now() + chrono::milliseconds(max<long long>(timeoutMs, 0));
    modifyFd(client.fd, clientEvents(client));
}

void EventLoop::unblockClient(ClientConnection &client, const string &bytes) {
    client.blocked = false;
    client.reason = BlockReason::None;
    client.blockedKey.clear();
    client.blockedResolvedStreams.clear();
    client.blockedRequestArr.clear();
    client.blockHasTimeout = false;

    queueOutput(client, bytes);

    int fd = client.fd;
    auto itr = clients.find(fd);
    if(itr != clients.end() && !itr->second.blocked)
        consumeClientCommands(itr->second);
}

void EventLoop::runPostCommandHooks(const string &cmd, const RESPValue &req, const string &response) {
    if(!response.empty() && response[0] == '-')
        return;

    if(!holds_alternative<RESPArray>(req.value))
        return;

    const RESPArray &arr = get<RESPArray>(req.value);

    if((cmd == "RPUSH" || cmd == "LPUSH")) {
        if(arr.size() >= 2 && holds_alternative<string>(arr[1].value))
            wakeBlockedListClients(get<string>(arr[1].value));
    } else if(cmd == "XADD") {
        if(arr.size() >= 2 && holds_alternative<string>(arr[1].value))
            wakeBlockedStreamClients(get<string>(arr[1].value));
    } else if(cmd == "REPLCONF") {
        checkBlockedWaits();
    }
}

void EventLoop::wakeBlockedListClients(const string &key) {
    while(true) {
        auto it = blockedListClients.find(key);
        if(it == blockedListClients.end() || it->second.empty())
            return;

        auto value = store.tryLpop(key);
        if(!value)
            return;

        int fd = it->second.front();
        it->second.pop_front();
        if(it->second.empty())
            blockedListClients.erase(it);

        auto clientItr = clients.find(fd);
        if(clientItr == clients.end())
            continue;

        ClientConnection &waiter = clientItr->second;
        RESPValue reply = waiter.handler->finalizeBlpop(key, *value, waiter.blockedRequestArr);
        unblockClient(waiter, serializer.serialize(reply));
    }
}

void EventLoop::wakeBlockedStreamClients(const string &key) {
    while(true) {
        auto it = blockedStreamClients.find(key);
        if(it == blockedStreamClients.end() || it->second.empty())
            return;

        vector<int> candidates(it->second.begin(), it->second.end());
        bool wokeAny = false;

        for(int fd : candidates) {
            auto clientItr = clients.find(fd);
            if(clientItr == clients.end())
                continue;

            ClientConnection &waiter = clientItr->second;
            if(!waiter.blocked || waiter.reason != BlockReason::XREAD)
                continue;

            auto result = waiter.handler->resolveXread(waiter.blockedResolvedStreams);
            if(!result)
                continue;

            removeStreamClientRegistrations(fd, waiter.blockedResolvedStreams);
            wokeAny = true;
            unblockClient(waiter, serializer.serialize(*result));
        }

        if(!wokeAny)
            return;
    }
}

void EventLoop::checkBlockedWaits() {
    for(auto it = blockedWaitClients.begin(); it != blockedWaitClients.end();) {
        int acked = replication.countAcked(it->targetOffset);
        if(acked < it->numReplicas) {
            ++it;
            continue;
        }

        int fd = it->fd;
        it = blockedWaitClients.erase(it);

        auto clientItr = clients.find(fd);
        if(clientItr == clients.end())
            continue;

        ClientConnection &waiter = clientItr->second;
        RESPValue reply{(long long)acked, ':'};
        unblockClient(waiter, serializer.serialize(reply));
    }
}

void EventLoop::removeListClientRegistration(int fd, const string &key) {
    auto it = blockedListClients.find(key);
    if(it == blockedListClients.end())
        return;

    auto &dq = it->second;
    dq.erase(remove(dq.begin(), dq.end(), fd), dq.end());
    if(dq.empty())
        blockedListClients.erase(it);
}

void EventLoop::removeStreamClientRegistrations(int fd, const vector<pair<string, string>> &resolvedStreams) {
    for(const auto &[key, _] : resolvedStreams) {
        auto it = blockedStreamClients.find(key);
        if(it == blockedStreamClients.end())
            continue;

        auto &dq = it->second;
        dq.erase(remove(dq.begin(), dq.end(), fd), dq.end());
        if(dq.empty())
            blockedStreamClients.erase(it);
    }
}

int EventLoop::computeNextTimeoutMs() {
    optional<chrono::steady_clock::time_point> earliest;

    for(auto &[fd, client] : clients) {
        if(client.blocked && client.blockHasTimeout) {
            if(!earliest || client.blockDeadline < *earliest)
                earliest = client.blockDeadline;
        }
    }

    if(!earliest)
        return -1;

    auto now = chrono::steady_clock::now();
    if(*earliest <= now)
        return 0;

    long long ms = chrono::duration_cast<chrono::milliseconds>(*earliest - now).count();
    return (int)min<long long>(ms + 1, 3600000);
}

void EventLoop::checkBlockedTimeouts() {
    if(clients.empty())
        return;

    auto now = chrono::steady_clock::now();
    vector<int> expiredFds;

    for(auto &[fd, client] : clients)
        if(client.blocked && client.blockHasTimeout && client.blockDeadline <= now)
            expiredFds.push_back(fd);

    for(int fd : expiredFds) {
        auto itr = clients.find(fd);
        if(itr == clients.end())
            continue;

        ClientConnection &client = itr->second;
        if(!client.blocked)
            continue;

        if(client.reason == BlockReason::BLPOP) {
            removeListClientRegistration(fd, client.blockedKey);
            unblockClient(client, serializer.serialize(RESPValue{nullptr, '*'}));
        } else if(client.reason == BlockReason::XREAD) {
            removeStreamClientRegistrations(fd, client.blockedResolvedStreams);
            unblockClient(client, serializer.serialize(RESPValue{nullptr, '*'}));
        } else if(client.reason == BlockReason::WAIT) {
            auto wit = find_if(blockedWaitClients.begin(), blockedWaitClients.end(),
                [fd](const PendingWait &pw) { return pw.fd == fd; });

            long long acked = 0;
            if(wit != blockedWaitClients.end()) {
                acked = replication.countAcked(wit->targetOffset);
                blockedWaitClients.erase(wit);
            }

            unblockClient(client, serializer.serialize(RESPValue{acked, ':'}));
        }
    }
}

void EventLoop::adoptMasterConnection(int fd, string &&pendingBytes) {
    if(!setNonBlocking(fd))
        throw runtime_error("Failed to make master connection non-blocking");

    ClientConnection client;
    client.fd = fd;
    client.role = ConnectionRole::MasterLink;
    client.inputBuffer = move(pendingBytes);
    client.handler = make_shared<RequestHandler>(
        store,
        serializer,
        config,
        replication,
        aof,
        fd);

    clients.emplace(fd, move(client));
    addFd(fd, EPOLLIN | EPOLLRDHUP);

    auto itr = clients.find(fd);
    if(itr != clients.end() && !itr->second.inputBuffer.empty())
        consumeClientCommands(itr->second);
}
