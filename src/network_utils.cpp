#include "network_utils.h"
#include <cerrno>
#include <iostream>
#include <mutex>
#include <sys/socket.h>
#include <csignal>
#include <utility>

namespace {
mutex interceptorMutex;
SendInterceptor sendInterceptor;
}

void set_send_interceptor(SendInterceptor interceptor)
{
    lock_guard<mutex> lock(interceptorMutex);
    sendInterceptor = move(interceptor);
}

void send_msg(const string &message, int clientFd)
{
    SendInterceptor interceptor;
    {
        lock_guard<mutex> lock(interceptorMutex);
        interceptor = sendInterceptor;
    }

    if(interceptor && interceptor(clientFd, message))
        return;

    size_t total_sent = 0;
    while (total_sent < message.size())
    {
        ssize_t byte_sent = send(
            clientFd,
            message.data() + total_sent,
            message.size() - total_sent,
            MSG_NOSIGNAL);

        if (byte_sent == -1)
        {
            if (errno == EINTR)
                continue;

            cout << "Error sending the msg.\n";
            return;
        }

        if (byte_sent == 0)
            return;

        total_sent += static_cast<size_t>(byte_sent);
    }
}
