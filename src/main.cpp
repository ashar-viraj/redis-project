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

using namespace std;

#define MAX_BUFFER_LEN 1024

// Important
void send_msg(const string &message, int client_fd)
{
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

void recieve_msg(int client_fd,
                 RESPParser &parser,
                 RequestHandler &handler,
                 RESPSerializer &serializer)
{
  char buffer[MAX_BUFFER_LEN] = {0};
  const char *pong = "+PONG\r\n";
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

int main(int argc, char **argv)
{
  // Flush after every std::cout / std::cerr
  std::cout << std::unitbuf;
  std::cerr << std::unitbuf;

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
  server_addr.sin_port = htons(6379);

  if (bind(server_fd, (struct sockaddr *)&server_addr, sizeof(server_addr)) != 0)
  {
    std::cerr << "Failed to bind to port 6379\n";
    return 1;
  }

  int connection_backlog = 5;
  if (listen(server_fd, connection_backlog) != 0)
  {
    std::cerr << "listen failed\n";
    return 1;
  }

  struct sockaddr_in client_addr;
  int client_addr_len = sizeof(client_addr);
  std::cout << "Waiting for a client to connect...\n";

  // You can use print statements as follows for debugging, they'll be visible when running tests.
  std::cout << "Logs from your program will appear here!\n";

  // Uncomment the code below to pass the first stage

  Store store;

  RESPParser parser;
  RequestHandler handler(store);
  RESPSerializer serializer;

  while (true)
  {
    int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, (socklen_t *)&client_addr_len);
    if (client_fd < 0)
    {
      cout << "Client connection failed.\n";
      continue;
    }
    // std::cout << "Client connected\n";
    thread(recieve_msg, client_fd, ref(parser), ref(handler), ref(serializer)).detach();

    // recieve_msg(client_fd);
  }
  close(server_fd);

  return 0;
}
