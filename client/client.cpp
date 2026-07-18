#include <iostream>
#include <string>
#include <vector>
#include <sstream>
#include <cstring>
#include <cctype>
#include <cerrno>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <thread>
#include <mutex>
#include <atomic>

static std::string encodeRESP(const std::vector<std::string> &tokens)
{
    std::string out;
    out += "*" + std::to_string(tokens.size()) + "\r\n";
    for (const auto &t : tokens)
    {
        out += "$" + std::to_string(t.size()) + "\r\n";
        out += t + "\r\n";
    }
    return out;
}

static std::vector<std::string> tokenize(const std::string &line)
{
    std::vector<std::string> tokens;
    size_t i = 0;
    while (i < line.size())
    {
        while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) ++i;
        if (i >= line.size()) break;

        if (line[i] == '"')
        {
            ++i;
            std::string tok;
            while (i < line.size() && line[i] != '"')
            {
                if (line[i] == '\\' && i + 1 < line.size()) ++i;
                tok += line[i++];
            }
            if (i < line.size()) ++i;
            tokens.push_back(tok);
        }
        else
        {
            std::string tok;
            while (i < line.size() && !std::isspace(static_cast<unsigned char>(line[i])))
                tok += line[i++];
            tokens.push_back(tok);
        }
    }
    return tokens;
}

static bool sendAll(int fd, const std::string &data)
{
    size_t sent = 0;
    while (sent < data.size())
    {
        ssize_t n = send(fd, data.data() + sent, data.size() - sent, 0);
        if (n < 0)
        {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

static bool recvByte(int fd, char &c)
{
    while (true)
    {
        ssize_t n = recv(fd, &c, 1, 0);
        if (n == 1) return true;
        if (n == 0) return false;
        if (errno == EINTR) continue;
        return false;
    }
}

static bool readLine(int fd, std::string &line)
{
    line.clear();
    char c;
    while (true)
    {
        if (!recvByte(fd, c)) return false;
        if (c == '\r') continue;
        if (c == '\n') return true;
        line.push_back(c);
    }
}

static void printIndent(int n)
{
    std::cout << std::string(n, ' ');
}

// Guards std::cout so the receiver thread and the main thread don't
// interleave partial writes.
static std::mutex g_coutMutex;

// Set to false once the connection should be torn down (EOF from the
// user, socket closed by the server, quit command, etc.) so both
// threads know to stop.
static std::atomic<bool> g_running{true};

struct RespValue {
    enum Type { SIMPLE, ERROR, INTEGER, BULK, ARRAY, NIL } type;
    std::string text;
    std::vector<RespValue> items;
};

static bool readExact(int fd, std::string &data, size_t len)
{
    data.resize(len);
    size_t off = 0;

    while (off < len)
    {
        ssize_t n = recv(fd, &data[off], len - off, 0);
        if (n < 0)
        {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        off += static_cast<size_t>(n);
    }

    char crlf[2];
    size_t got = 0;
    while (got < 2)
    {
        ssize_t n = recv(fd, crlf + got, 2 - got, 0);
        if (n < 0)
        {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        got += static_cast<size_t>(n);
    }

    return crlf[0] == '\r' && crlf[1] == '\n';
}

static bool parseResp(int fd, RespValue &out)
{
    std::string line;
    if (!readLine(fd, line) || line.empty()) return false;

    char type = line[0];
    std::string body = line.substr(1);

    switch (type)
    {
        case '+':
            out.type = RespValue::SIMPLE;
            out.text = body;
            return true;

        case '-':
            out.type = RespValue::ERROR;
            out.text = body;
            return true;

        case ':':
            out.type = RespValue::INTEGER;
            out.text = body;
            return true;

        case '$':
        {
            long long len = std::stoll(body);
            if (len == -1)
            {
                out.type = RespValue::NIL;
                return true;
            }

            std::string data;
            if (!readExact(fd, data, static_cast<size_t>(len))) return false;
            out.type = RespValue::BULK;
            out.text = std::move(data);
            return true;
        }

        case '*':
        {
            long long count = std::stoll(body);
            if (count == -1)
            {
                out.type = RespValue::NIL;
                return true;
            }

            out.type = RespValue::ARRAY;
            out.items.clear();
            out.items.reserve(static_cast<size_t>(count));

            for (long long i = 0; i < count; ++i)
            {
                RespValue child;
                if (!parseResp(fd, child)) return false;
                out.items.push_back(std::move(child));
            }
            return true;
        }

        default:
            return false;
    }
}

static void printPretty(const RespValue &v, int indent = 0)
{
    std::string pad(indent, ' ');

    switch (v.type)
    {
        case RespValue::SIMPLE:
            std::cout << v.text;
            break;

        case RespValue::ERROR:
            std::cout << "(error) " << v.text << "";
            break;

        case RespValue::INTEGER:
            std::cout << v.text;
            break;

        case RespValue::BULK:
            std::cout << v.text;
            break;

        case RespValue::NIL:
            std::cout << "null";
            break;

        case RespValue::ARRAY:
            std::cout << "[\n";
            for (size_t i = 0; i < v.items.size(); ++i)
            {
                std::cout << std::string(indent + 2, ' ');
                printPretty(v.items[i], indent + 2);
                if (i + 1 < v.items.size()) std::cout << ",";
                std::cout << "\n";
            }
            std::cout << pad << "]";
            break;
    }
}

static bool readResponse(int fd)
{
    RespValue v;
    if (!parseResp(fd, v)) return false;

    std::lock_guard<std::mutex> lock(g_coutMutex);
    printPretty(v);
    std::cout << "\n";
    std::cout.flush();
    return true;
}

int main(int argc, char **argv)
{
    const char *host = "127.0.0.1";
    int port = 6379;

    if (argc >= 2) host = argv[1];
    if (argc >= 3) port = std::stoi(argv[2]);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, host, &addr.sin_addr);

    if (connect(fd, (sockaddr *)&addr, sizeof(addr)) < 0)
    {
        perror("connect");
        std::cerr << "Could not connect to " << host << ":" << port << "\n";
        return 1;
    }

    std::cout << "Connected to " << host << ":" << port << "\n";
    std::cout << "Type Redis commands (e.g. SET foo bar, GET foo, PING). Ctrl+D to exit.\n\n";

    // The server can push data at any time (Pub/Sub messages, for example),
    // not just as a reply to something we just sent. So reading the socket
    // can't be tied to "we just sent a command" - it has to run continuously
    // on its own thread, independent of when the user types something.
    std::thread receiver([&]() {
        while (g_running.load())
        {
            if (!readResponse(fd))
            {
                if (g_running.exchange(false))
                {
                    std::lock_guard<std::mutex> lock(g_coutMutex);
                    std::cout << "\nConnection closed by server\n";
                }
                // Unblock a getline() that may be waiting on stdin.
                shutdown(fd, SHUT_RDWR);
                break;
            }
        }
    });

    std::string line;
    while (g_running.load())
    {
        {
            std::lock_guard<std::mutex> lock(g_coutMutex);
            std::cout << host << ":" << port << "> ";
            std::cout.flush();
        }

        if (!std::getline(std::cin, line)) break;
        if (line.empty()) continue;
        if (line == "quit" || line == "exit") break;

        auto tokens = tokenize(line);
        if (tokens.empty()) continue;

        std::string req = encodeRESP(tokens);
        if (!sendAll(fd, req))
        {
            std::lock_guard<std::mutex> lock(g_coutMutex);
            std::cerr << "Send failed\n";
            break;
        }
        // No readResponse() call here: the receiver thread owns all
        // reading from the socket now, whether it's the reply to this
        // command or an unsolicited Pub/Sub message that shows up later.
    }

    // Tell the receiver thread to stop and wake it up if it's blocked
    // in recv().
    g_running.store(false);
    shutdown(fd, SHUT_RDWR);
    receiver.join();

    close(fd);
    return 0;
}