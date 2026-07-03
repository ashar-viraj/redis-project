#pragma once

#include <string>

struct Config {
    int port = 6379;

    bool isReplica = false;

    string masterHost;
    int masterPort = 6379;

    string masterReplId = "8371b4fb1155b71f4a04d3e1bc3e18c4a990aeeb";
    long long masterReplOffset = 0;

    int masterFd = -1;
};