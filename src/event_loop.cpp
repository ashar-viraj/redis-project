#include "event_loop.h"

#include "empty_rdb.h"
#include "network_utils.h"

#include <arpa/inet.h>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <stdexcept>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <unistd.h>

using namespace std;

namespace {
constexpr int MAX_EVENTS = 128;
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

    wakeFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if(wakeFd == -1)
        throw runtime_error("Failed to create eventfd");

    if(!setNonBlocking(serverFd))
        throw runtime_error("Failed to make server socket non-blocking");

    addFd(serverFd, EPOLLIN);
    addFd(wakeFd, EPOLLIN);

    set_send_interceptor([this](int fd, const string &bytes) {
        return queueOutputFromAnyThread(fd, bytes);
    });
}

EventLoop::~EventLoop() {
    set_send_interceptor(nullptr);

    for(auto &[fd, _] : clients)
        close(fd);

    if(wakeFd != -1)
        close(wakeFd);
    if(epollFd != -1)
        close(epollFd);
}

void EventLoop::run() {
    loopThreadId = this_thread::get_id();
    vector<epoll_event> events(MAX_EVENTS);

    while(true) {
        int ready = epoll_wait(epollFd, events.data(), MAX_EVENTS, -1);
        if(ready == -1) {
            if(errno == EINTR)
                continue;
            throw runtime_error(string("epoll_wait failed: ") + strerror(errno));
        }

        for(int i = 0; i < ready; i++) {
            int fd = events[i].data.fd;
            uint32_t ev = events[i].events;

            if(fd == serverFd) {
                acceptNewClients();
                continue;
            }

            if(fd == wakeFd) {
                drainWakeFd();
                drainExternalOutputs();
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

                if(itr->second.outputBuffer.empty() && !itr->second.blocked)
                    removeClient(fd);
                else {
                    itr->second.closeAfterWrite = true;
                    modifyFd(fd, clientEvents(itr->second));
                }
            }
        }
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
        registerManagedFd(clientFd);
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
        if(afterConsume->second.outputBuffer.empty() && !afterConsume->second.blocked)
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

            queueOutput(client, "-" + msg + "\r\n");
            client.inputBuffer.clear();
            break;
        }

        client.inputBuffer.erase(0, bytesConsumed);

        string cmd = extractCommandName(req);
        bool sendRdb = (!config.isReplica && cmd == "PSYNC");

        if(commandShouldRunOffLoop(client, req, cmd)) {
            startOffLoopCommand(client, req);
            break;
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
    }
}

void EventLoop::removeClient(int fd) {
    auto itr = clients.find(fd);
    if(itr == clients.end())
        return;

    unregisterManagedFd(fd);
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

bool EventLoop::queueOutputFromAnyThread(int fd, const string &bytes) {
    if(isRetiredManagedFd(fd))
        return true;

    if(!isManagedFd(fd))
        return false;

    if(this_thread::get_id() == loopThreadId)
        return queueOutput(fd, bytes);

    enqueueExternalOutput(fd, bytes, false);
    return true;
}

void EventLoop::enqueueExternalOutput(int fd, const string &bytes, bool unblockClient) {
    {
        lock_guard<mutex> lock(externalOutputsMutex);
        externalOutputs.push_back({fd, bytes, unblockClient});
    }
    wake();
}

void EventLoop::drainExternalOutputs() {
    vector<ExternalOutput> pending;
    {
        lock_guard<mutex> lock(externalOutputsMutex);
        pending.swap(externalOutputs);
    }

    vector<int> clientsToResume;

    for(auto &output : pending) {
        auto itr = clients.find(output.fd);
        if(itr == clients.end())
            continue;

        ClientConnection &client = itr->second;
        if(output.unblockClient) {
            client.blocked = false;
            clientsToResume.push_back(output.fd);
        }

        queueOutput(client, output.bytes);
    }

    for(int fd : clientsToResume) {
        auto itr = clients.find(fd);
        if(itr != clients.end() && !itr->second.blocked)
            consumeClientCommands(itr->second);
    }
}

void EventLoop::wake() {
    uint64_t one = 1;
    ssize_t written = write(wakeFd, &one, sizeof(one));
    if(written == -1 && errno != EAGAIN && errno != EWOULDBLOCK)
        cout << "Failed to wake event loop: " << strerror(errno) << "\n";
}

void EventLoop::drainWakeFd() {
    uint64_t value;
    while(true) {
        ssize_t readBytes = read(wakeFd, &value, sizeof(value));
        if(readBytes > 0)
            continue;

        if(readBytes == -1 && errno == EINTR)
            continue;

        if(readBytes == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
            break;

        break;
    }
}

void EventLoop::registerManagedFd(int fd) {
    lock_guard<mutex> lock(managedFdsMutex);
    retiredManagedFds.erase(fd);
    managedFds.insert(fd);
}

void EventLoop::unregisterManagedFd(int fd) {
    lock_guard<mutex> lock(managedFdsMutex);
    managedFds.erase(fd);
    retiredManagedFds.insert(fd);
}

bool EventLoop::isManagedFd(int fd) {
    lock_guard<mutex> lock(managedFdsMutex);
    return managedFds.count(fd) != 0;
}

bool EventLoop::isRetiredManagedFd(int fd) {
    lock_guard<mutex> lock(managedFdsMutex);
    return retiredManagedFds.count(fd) != 0;
}

bool EventLoop::commandShouldRunOffLoop(ClientConnection &client, const RESPValue &req, const string &cmd) {
    if(!client.handler->state.authenticated)
        return false;

    if(client.handler->state.inTransaction)
        return false;

    if(cmd == "BLPOP" || cmd == "WAIT")
        return true;

    if(cmd != "XREAD" || req.type != '*')
        return false;

    const RESPArray &arr = get<RESPArray>(req.value);
    if(arr.size() < 2 || !holds_alternative<string>(arr[1].value))
        return false;

    string firstKeyword = get<string>(arr[1].value);
    toUpper(firstKeyword);
    return firstKeyword == "BLOCK";
}

void EventLoop::startOffLoopCommand(ClientConnection &client, const RESPValue &req) {
    client.blocked = true;
    modifyFd(client.fd, clientEvents(client));

    int fd = client.fd;
    shared_ptr<RequestHandler> handler = client.handler;

    thread([this, fd, handler, req]() {
        string response = executeOffLoopCommand(handler, req);
        enqueueExternalOutput(fd, response, true);
    }).detach();
}

string EventLoop::executeOffLoopCommand(shared_ptr<RequestHandler> handler, const RESPValue &req) {
    try {
        RESPValue res = handler->handle(req);
        return serializer.serialize(res);
    } catch(const exception &e) {
        return "-" + string(e.what()) + "\r\n";
    } catch(...) {
        return "-ERR unknown error\r\n";
    }
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
