#pragma once

#include <string>
#include <vector>
using namespace std;

struct User {
    string name = "default";
    bool nopass = true;
    vector<string> passwordHashes;
};

struct Config {
    int port = 6379;

    bool isReplica = false;

    string masterHost;
    int masterPort = 6379;
    string masterReplId = "8371b4fb1155b71f4a04d3e1bc3e18c4a990aeeb";

    string dir;
    string dbFileName;

    int masterFd = -1;

    bool appendOnly = false;
    string appendDirName = "appendonlydir";
    string appendFileName = "appendonly.aof";
    string appendFsync = "everysec";

    User defaultUser;
};