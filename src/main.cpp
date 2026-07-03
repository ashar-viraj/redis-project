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

#include "RESP/resp_parser.h"
#include "request_handler.h"
#include "RESP/resp_serializer.h"
#include "config.h"

using namespace std;

#define MAX_BUFFER_LEN 1024

// Important
void send_msg(const string &message, int client_fd) {
  size_t total_sent = 0;
  while (total_sent < message.size())
  {
    ssize_t byte_sent = send(
        client_fd,
        message.data() + total_sent,
        message.size() - total_sent,
        0);

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

string receive_msg(int sock_fd) {
  char buffer[1024] = {0};

  int len = recv(sock_fd, buffer, sizeof(buffer)-1, 0);
  if(len <= 0)
    return "";

  return string(buffer, len);
}

void handleClient(int client_fd,
                 RESPParser &parser,
                 Store &store,
                //  RequestHandler &handler,
                 RESPSerializer &serializer,
                Config &config) {
  RequestHandler handler(store, config);

  char buffer[MAX_BUFFER_LEN] = {0};
  while (true)
  {
    memset(buffer, 0, sizeof(buffer));

    int msg_len = recv(client_fd, buffer, sizeof(buffer) - 1, 0);
    if (msg_len <= 0)
      break;
    // cout << "msg len : " << msg_len << (int)buffer[msg_len] << endl;
    buffer[msg_len] = '\0';

    string resStr;
    try{
      RESPValue req = parser.parse(buffer);

      RESPValue res = handler.handle(req);

      resStr = serializer.serialize(res);

    } catch (const exception &e) {
      resStr = "-" + string(e.what()) + "\r\n";
    }catch(...) {
      resStr = "-ERR unknown error\r\n";
    }
    send_msg(resStr, client_fd);
  }

  close(client_fd);
}

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

bool connectToMaster(Config &config, RESPSerializer &serializer) {
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

  return true;
}

int main(int argc, char **argv)
{
  // Flush after every std::cout / std::cerr
  std::cout << std::unitbuf;
  std::cerr << std::unitbuf;

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

  if(config.isReplica) {
    if(!connectToMaster(config, serializer)) {
      cerr << "Failed to connect to master\n";
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

  struct sockaddr_in client_addr;
  socklen_t client_addr_len = sizeof(client_addr);
  std::cout << "Waiting for a client to connect...\n";

  // You can use print statements as follows for debugging, they'll be visible when running tests.
  std::cout << "Logs from your program will appear here!\n";

  // Uncomment the code below to pass the first stage

  Store store;

  RESPParser parser;

  while (true)
  {
    int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, (socklen_t *)&client_addr_len);
    if (client_fd < 0)
    {
      cout << "Client connection failed.\n";
      continue;
    }
    // std::cout << "Client connected\n";
    thread(handleClient, client_fd, ref(parser), ref(store), ref(serializer), ref(config)).detach();

    // handleClient(client_fd);
  }
  close(server_fd);

  return 0;
}
