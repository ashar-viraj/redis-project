#include <iostream>
#include <cstdlib>
#include <string>
#include <cstring>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <thread>
#include <vector>
#include <cerrno>
#include <csignal>

#include "config.h"
#include "empty_rdb.h"
#include "network_utils.h"
#include "replication_manager.h"
#include "request_handler.h"
#include "RESP/resp_parser.h"
#include "RESP/resp_serializer.h"

using namespace std;

#define MAX_BUFFER_LEN 1024


string escapeRESP(const string &s) {
    string out;
    for (char c : s) {
        if (c == '\r')
            out += "\\r";
        else if (c == '\n')
            out += "\\n\n";
        else
            out += c;
    }
    return out;
}

string receive_msg(int sock_fd) {
  char buffer[1024] = {0};

  int len = recv(sock_fd, buffer, sizeof(buffer)-1, 0);

  if(len <= 0)
    return "";

  return string(buffer, len);
}

// Parses and executes as many complete RESP commands as are already sitting
// in `pending`, WITHOUT touching the socket. Stops as soon as what's left
// doesn't form a complete command yet (or pending is empty).
void consumeCommands(int sock_fd,
                      string &pending,
                      RESPParser &parser,
                      RequestHandler &handler,
                      RESPSerializer &serializer,
                      Config &config,
                      ReplicationManager &replication,
                      bool sendResponse) {
  while (!pending.empty()) {
    size_t bytesConsumed = 0;
    RESPValue req;

    try {
      cout << "===================Request pending===================\n" << escapeRESP(pending) << endl;
      req = parser.parse(pending, bytesConsumed);
    } catch (const exception &e) {
      string msg = e.what();
      if (msg == "Incomplete RESP message") {
        // Not enough bytes buffered yet for a full command. Leave `pending`
        // untouched and wait for the next recv() to bring the rest.
        break;
      }

      // A genuinely malformed command (not just incomplete). Report it and
      // drop the buffer so we don't spin forever trying to reparse garbage.
      if (sendResponse)
        send_msg("-" + msg + "\r\n", sock_fd);
      else
        cout << "ERR while replicating : " << msg << endl;

      pending.clear();
      break;
    }

    // Successfully parsed one full command -- remove exactly the bytes that
    // belonged to it and keep whatever (possibly partial) data follows.
    pending.erase(0, bytesConsumed);

    string resStr;
    bool sendRdb = false;

    try {
      if (sendResponse) {
        RESPArray arr = get<RESPArray>(req.value);
        if (!arr.empty()) {
          string cmd = get<string>(arr[0].value);
          toUpper(cmd);

          sendRdb = (!config.isReplica && cmd == "PSYNC");
        }
      }

      RESPValue res = handler.handle(req);

      resStr = serializer.serialize(res);
      cout << "=============Recieved=============\n";
      cout << resStr << endl;
    } catch (const exception &e) {
      resStr = "-" + string(e.what()) + "\r\n";
    } catch (...) {
      resStr = "-ERR unknown error\r\n";
    }

    bool shouldReply = sendResponse;

    if(!sendResponse) {
      RESPArray arr = get<RESPArray>(req.value);

      string cmd = get<string>(arr[0].value);
      toUpper(cmd);

      if(cmd == "REPLCONF" && arr.size() >= 2) {
        string sub = get<string>(arr[1].value);
        toUpper(sub);

        if(sub == "GETACK")
          shouldReply = true;
      }
    }

    if(shouldReply) {
      send_msg(resStr, sock_fd);

      if (sendRdb) {
        string rdb = getEmptyRdb();
        send_msg("$" + to_string(rdb.size()) + "\r\n", sock_fd);
        send_msg(rdb, sock_fd);
      }
    } else if (!resStr.empty()) {
      cout << "ERR while replicating : " << resStr << endl;
    }

    if(!sendResponse)
      replication.addProcessedOffset(bytesConsumed);
  }
}

// Reads whatever is available on sock_fd, appends it to `pending`, and then
// hands off to consumeCommands() to parse/execute as many complete RESP
// commands as are now buffered.
//
// Returns false when the connection has been closed / recv() failed, so the
// caller knows to stop looping and clean up.
bool processIncomingStream(int sock_fd,
                            string &pending,
                            RESPParser &parser,
                            RequestHandler &handler,
                            RESPSerializer &serializer,
                            Config &config,
                            ReplicationManager &replication,
                            bool sendResponse) {
  char buffer[MAX_BUFFER_LEN];

  int msg_len = recv(sock_fd, buffer, sizeof(buffer), 0);
  if (msg_len <= 0)
    return false;

  pending.append(buffer, msg_len);

  consumeCommands(sock_fd, pending, parser, handler, serializer, config, replication, sendResponse);

  return true;
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
// the first propagated command.
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
  cout << "Handshake reply: " << fullresyncLine << endl;

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

  cout << "Consumed RDB payload (" << rdbLen << " bytes)\n";
  return true;
}


void handleClient(int client_fd,
                RESPParser &parser,
                Store &store,
                RESPSerializer &serializer,
                ReplicationManager &replication,
                Config &config) {
  RequestHandler handler(store, config, replication, client_fd);

  string pending;
  while (processIncomingStream(client_fd, pending, parser, handler, serializer, config, replication, /*sendResponse=*/true)) {
    // keep looping while the connection stays open
  }

  close(client_fd);
}

void receiveFromMaster(RESPParser &parser,
                      Store &store,
                      RESPSerializer &serializer,
                      ReplicationManager &replication,
                      Config &config,
                      string pending) {
  RequestHandler handler(store, config, replication, config.masterFd);

  try {
    if (!consumeFullResyncAndRdb(config.masterFd, pending)) {
      cout << "Master closed connection while transferring RDB.\n";
      close(config.masterFd);
      return;
    }
  } catch (const exception &e) {
    cout << "ERR consuming RDB from master: " << e.what() << endl;
    close(config.masterFd);
    return;
  }

  // Anything that arrived bundled right behind the RDB bytes in the same
  // recv() (e.g. a propagated SET) is already sitting in `pending` -- handle
  // it before going back to the socket for more.
  consumeCommands(config.masterFd, pending, parser, handler, serializer, config, replication, /*sendResponse=*/false);

  while (processIncomingStream(config.masterFd, pending, parser, handler, serializer, config, replication, /*sendResponse=*/false)) {
    // keep looping while the connection stays open
  }

  close(config.masterFd);
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
  // receiveFromMaster() so nothing gets silently dropped.
  string lastReceived;

  auto sendAndReceive = [&](const RESPArray &cmd) {
    // cout << "===========Sending==========="<< endl;
    // cout << escapeRESP(serializer.serialize({cmd, '*'})) << endl;
    send_msg(serializer.serialize({cmd, '*'}), config.masterFd);
    
    string recieved = receive_msg(config.masterFd);
    // cout << "===========Recieved==========="<< endl;
    // cout << escapeRESP(recieved) << endl;
    if (recieved.empty()) {
      // cout << "Connection closed by master.\n";
      close(config.masterFd);
      config.masterFd = -1;
      return false;
    }
    lastReceived = recieved;
    return true;
  };

  if (!sendAndReceive({ RESPValue("PING", '$')})) 
    return false;

  // REPLCONF listening-port <port>
  // cout << "Config port : " << config.port << endl;
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

  // Hand off whatever came back with the PSYNC reply so receiveFromMaster
  // can strip the FULLRESYNC line + RDB payload from it correctly.
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

  for(int i = 1; i < argc; i++) {
    string arg = argv[i];

    if(arg == "--port" && i + 1 < argc)
      config.port = stoi(argv[++i]);

    if (arg == "--replicaof" && i + 1 < argc) {
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
  }

  RESPSerializer serializer;
  RESPParser parser;
  Store store;
  ReplicationManager replication(serializer);

  if(config.isReplica) {
    string masterPending;
    if(!connectToMaster(config, serializer, masterPending)) {
      cerr << "Failed to connect to master\n";
      return 1;
    }
    thread(receiveFromMaster, ref(parser), ref(store), ref(serializer), ref(replication), ref(config), masterPending).detach();
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

  struct sockaddr_in client_addr;
  socklen_t client_addr_len = sizeof(client_addr);
  std::cout << "Waiting for a client to connect...\n";

  // You can use print statements as follows for debugging, they'll be visible when running tests.
  std::cout << "Logs from your program will appear here!\n";

  // Uncomment the code below to pass the first stage

  while (true)
  {
    int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, (socklen_t *)&client_addr_len);
    if (client_fd < 0)
    {
      cout << "Client connection failed.\n";
      continue;
    }
    // std::cout << "Client connected\n";
    thread(handleClient, client_fd, ref(parser), ref(store), ref(serializer), ref(replication), ref(config)).detach();

    // handleClient(client_fd);
  }
  close(server_fd);

  return 0;
}