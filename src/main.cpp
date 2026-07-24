#include <arpa/inet.h>
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <netdb.h>
#include <string>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <vector>

#include "./AOF/aof_manager.h"
#include "config.h"
#include "empty_rdb.h"
#include "event_loop.h"
#include "network_utils.h"
#include "replication_manager.h"
#include "request_handler.h"
#include "RESP/resp_parser.h"
#include "RESP/resp_serializer.h"
#include "RDB/rdb_parser.h"

using namespace std;

#define MAX_BUFFER_LEN 1024

string receive_msg(int sock_fd) {
  char buffer[1024] = {0};

  int len = recv(sock_fd, buffer, sizeof(buffer)-1, 0);

  if(len <= 0)
    return "";

  return string(buffer, len);
}

// Right after PSYNC, the master replies with:
//   1) "+FULLRESYNC <replid> <offset>\r\n"          (a normal simple string)
//   2) "$<length>\r\n<raw rdb bytes>"                (NOT a normal bulk
//      string -- there is no trailing \r\n after the payload)
//
// Because (2) isn't valid RESP, it must never be handed to RESPParser::parse.
// This function strips both pieces directly out of `pending`, pulling more
// bytes off the socket as needed, and leaves `pending` holding only
// whatever (if anything) came after the RDB payload -- e.g. the start of
// the first propagated command. Runs once, synchronously, as part of the
// startup handshake -- ongoing traffic afterward is handled by EventLoop.
bool consumeFullResyncAndRdb(int sock_fd, string &pending) {
  auto readMore = [&]() -> bool {
    char buf[MAX_BUFFER_LEN];
    int len = recv(sock_fd, buf, sizeof(buf), 0);
    if (len <= 0)
      return false;
    pending.append(buf, len);
    return true;
  };

  // 1) Consume the "+FULLRESYNC <id> <offset>\r\n" line.
  size_t lineEnd;
  while ((lineEnd = pending.find("\r\n")) == string::npos) {
    if (!readMore())
      return false;
  }
  string fullresyncLine = pending.substr(0, lineEnd);
  pending.erase(0, lineEnd + 2);

  // 2) Consume the "$<length>\r\n" header describing the RDB payload.
  size_t hdrEnd;
  while ((hdrEnd = pending.find("\r\n")) == string::npos) {
    if (!readMore())
      return false;
  }
  if (pending.empty() || pending[0] != '$')
    throw runtime_error("Expected RDB bulk header from master");

  int rdbLen = stoi(pending.substr(1, hdrEnd - 1));
  pending.erase(0, hdrEnd + 2);

  // 3) Consume exactly rdbLen raw bytes. No trailing \r\n to strip here --
  // that's precisely what made the old code misparse this as a bulk string.
  while (pending.size() < (size_t)rdbLen) {
    if (!readMore())
      return false;
  }
  pending.erase(0, rdbLen);

  return true;
}

bool connectToMaster(Config &config, RESPSerializer &serializer, string &pendingAfterHandshake) {
  // IMPORTANT
  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  addrinfo *result = nullptr;

  int ret = getaddrinfo(
      config.masterHost.c_str(),
      std::to_string(config.masterPort).c_str(),
      &hints,
      &result);

  if (ret != 0) {
      std::cerr << "getaddrinfo: " << gai_strerror(ret) << '\n';
      return false;
  }

  config.masterFd = socket(
      result->ai_family,
      result->ai_socktype,
      result->ai_protocol);

  if (config.masterFd < 0) {
      freeaddrinfo(result);
      return false;
  }

  if (connect(config.masterFd,
              result->ai_addr,
              result->ai_addrlen) < 0) {
      close(config.masterFd);
      config.masterFd = -1;
      freeaddrinfo(result);
      return false;
  }

  freeaddrinfo(result);

  // Tracks whatever raw bytes came back from the most recent handshake
  // step. After the PSYNC step this will hold the "+FULLRESYNC ...\r\n"
  // line and possibly the start of the RDB bytes too (since they can
  // arrive in the same recv()) -- we hand all of it off to
  // consumeFullResyncAndRdb() so nothing gets silently dropped.
  string lastReceived;

  auto sendAndReceive = [&](const RESPArray &cmd) {
    send_msg(serializer.serialize({cmd, '*'}), config.masterFd);

    string received = receive_msg(config.masterFd);
    if (received.empty()) {
      close(config.masterFd);
      config.masterFd = -1;
      return false;
    }
    lastReceived = received;
    return true;
  };

  if (!sendAndReceive({ RESPValue("PING", '$')}))
    return false;

  // REPLCONF listening-port <port>
  if (!sendAndReceive({RESPValue("REPLCONF", '$'),
                       RESPValue("listening-port", '$'),
                       RESPValue(to_string(config.port), '$')}))
    return false;

  // REPLCONF capa psync2
  if (!sendAndReceive({RESPValue("REPLCONF", '$'),
                       RESPValue("capa", '$'),
                       RESPValue("psync2", '$')}))
    return false;

  // PSYNC <replication_id> <offset>
  if (!sendAndReceive({RESPValue("PSYNC", '$'),
                       RESPValue("?", '$'),
                       RESPValue("-1", '$')}))
    return false;
  // Continue with serializer / handshake...

  // Hand off whatever came back with the PSYNC reply so the caller can
  // strip the FULLRESYNC line + RDB payload from it correctly.
  pendingAfterHandshake = lastReceived;

  return true;
}

int main(int argc, char **argv)
{
  // Flush after every std::cout / std::cerr
  std::cout << std::unitbuf;
  std::cerr << std::unitbuf;
  signal(SIGPIPE, SIG_IGN);

  Config config;

  config.dir = filesystem::current_path().string();

  for(int i = 1; i < argc; i++) {
    string arg = argv[i];

    if(arg == "--port" && i + 1 < argc)
      config.port = stoi(argv[++i]);
    else if (arg == "--replicaof" && i + 1 < argc) {
      config.isReplica = true;

      string replicaArg = argv[++i];

      size_t pos = replicaArg.find(' ');

      if (pos != string::npos) {
          config.masterHost = replicaArg.substr(0, pos);
          config.masterPort = stoi(replicaArg.substr(pos + 1));
      } else {
          config.masterHost = replicaArg;

          if (i + 1 < argc)
              config.masterPort = stoi(argv[++i]);
      }
    }
    else if(arg == "--dir" && i+1 < argc) {
      config.dir = argv[++i];
    } else if(arg == "--dbfilename" && i+1 < argc) {
      config.dbFileName = argv[++i];
    } else if(arg == "--appendonly" && i+1 < argc) {
      string paramVal = argv[++i];
      toUpper(paramVal);
      config.appendOnly = (paramVal == "YES");
    } else if(arg == "--appenddirname" && i+1 < argc) {
      config.appendDirName = argv[++i];
    } else if(arg == "--appendfilename" && i+1 < argc) {
      config.appendFileName = argv[++i];
    } else if(arg == "--appendfsync" && i+1 < argc) {
      config.appendFsync = argv[++i];
    }
  }

  RESPSerializer serializer;
  Store store;
  ReplicationManager replication(serializer);
  RDBParser rdbParser;
  AOFManager aof(config, serializer);

  if(config.appendOnly) {
    aof.initialize();
    aof.replay(store, replication);
  }

  if(!config.dir.empty() && !config.dbFileName.empty()) {
    RDBParser rdbParser;
    string rdbPath = config.dir + "/" + config.dbFileName;
    rdbParser.load(rdbPath, store);
  }

  // Replication handshake (PING/REPLCONF/PSYNC + FULLRESYNC/RDB transfer) is
  // kept synchronous/blocking here, at startup, before the event loop exists.
  // Everything after that -- propagated writes, REPLCONF GETACK/ACK -- runs
  // through EventLoop::adoptMasterConnection() once the loop is up.
  string masterPending;
  if(config.isReplica) {
    if(!connectToMaster(config, serializer, masterPending)) {
      cerr << "Failed to connect to master\n";
      return 1;
    }

    try {
      if(!consumeFullResyncAndRdb(config.masterFd, masterPending)) {
        cerr << "Master closed connection while transferring RDB.\n";
        close(config.masterFd);
        return 1;
      }
    } catch(const exception &e) {
      cerr << "ERR consuming RDB from master: " << e.what() << endl;
      close(config.masterFd);
      return 1;
    }
  }

  int server_fd = socket(AF_INET, SOCK_STREAM, 0);
  if (server_fd < 0)
  {
    std::cerr << "Failed to create server socket\n";
    return 1;
  }

  // Since the tester restarts your program quite often, setting SO_REUSEADDR
  // ensures that we don't run into 'Address already in use' errors
  int reuse = 1;
  if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) < 0)
  {
    std::cerr << "setsockopt failed\n";
    return 1;
  }

  struct sockaddr_in server_addr;
  server_addr.sin_family = AF_INET;
  server_addr.sin_addr.s_addr = INADDR_ANY;
  server_addr.sin_port = htons(config.port);

  if (bind(server_fd, (struct sockaddr *)&server_addr, sizeof(server_addr)) != 0)
  {
    std::cerr << "Failed to bind to port " << config.port << endl;
    return 1;
  }

  int connection_backlog = 5;
  if (listen(server_fd, connection_backlog) != 0)
  {
    std::cerr << "listen failed\n";
    return 1;
  }

  std::cout << "Waiting for a client to connect...\n";

  // You can use print statements as follows for debugging, they'll be visible when running tests.
  std::cout << "Logs from your program will appear here!\n";

  try {
    EventLoop loop(server_fd, store, serializer, replication, aof, config);

    if(config.isReplica)
      loop.adoptMasterConnection(config.masterFd, move(masterPending));

    loop.run();
  } catch(const exception &e) {
    cerr << "Event loop failed: " << e.what() << "\n";
    close(server_fd);
    return 1;
  }

  close(server_fd);

  return 0;
}
