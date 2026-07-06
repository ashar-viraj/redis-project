#include "network_utils.h"
#include <iostream>
#include <sys/socket.h>
#include <csignal>

void send_msg(const string &message, int clientFd)
{
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
        cout << "Sent : " << total_sent << endl;
    }
}
