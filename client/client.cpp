#include <iostream>
#include <string>
#include <vector>
#include <sstream>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>

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
    std::istringstream ss(line);
    std::string tok;
    while (ss >> tok)
        tokens.push_back(tok);
    return tokens;
}

// Read one complete RESP response from the socket and print it human-readably.
static bool readResponse(int fd)
{
    // Read until we have a full response. We use a simple byte-at-a-time
    // approach which is fine for an interactive client.
    std::string buf;
    auto readLine = [&](std::string &out) -> bool {
        out.clear();
        while (true)
        {
            char c;
            int n = recv(fd, &c, 1, 0);
            if (n <= 0) return false;
            if (c == '\r') continue;
            if (c == '\n') return true;
            out += c;
        }
    };

    std::string firstLine;
    if (!readLine(firstLine) || firstLine.empty()) return false;

    char type = firstLine[0];
    std::string body = firstLine.substr(1);

    switch (type)
    {
    case '+': // Simple string
        std::cout << body << "\n";
        break;

    case '-': // Error
        std::cout << "(error) " << body << "\n";
        break;

    case ':': // Integer
        std::cout << "(integer) " << body << "\n";
        break;

    case '$': // Bulk string
    {
        int len = std::stoi(body);
        if (len == -1)
        {
            std::cout << "(nil)\n";
            break;
        }
        std::string data(len, '\0');
        int received = 0;
        while (received < len)
        {
            int n = recv(fd, &data[received], len - received, 0);
            if (n <= 0) return false;
            received += n;
        }
        // consume trailing \r\n
        char crlf[2];
        recv(fd, crlf, 2, 0);
        std::cout << "\"" << data << "\"\n";
        break;
    }

    case '*': // Array
    {
        int count = std::stoi(body);
        if (count == -1)
        {
            std::cout << "(nil)\n";
            break;
        }
        for (int i = 0; i < count; i++)
        {
            std::string elemLine;
            if (!readLine(elemLine) || elemLine.empty()) return false;
            char elemType = elemLine[0];
            std::string elemBody = elemLine.substr(1);
            std::cout << (i + 1) << ") ";
            if (elemType == '$')
            {
                int elen = std::stoi(elemBody);
                if (elen == -1) { std::cout << "(nil)\n"; continue; }
                std::string edata(elen, '\0');
                int received = 0;
                while (received < elen)
                {
                    int n = recv(fd, &edata[received], elen - received, 0);
                    if (n <= 0) return false;
                    received += n;
                }
                char crlf[2]; recv(fd, crlf, 2, 0);
                std::cout << "\"" << edata << "\"\n";
            }
            else if (elemType == '+') std::cout << elemBody << "\n";
            else if (elemType == ':') std::cout << "(integer) " << elemBody << "\n";
            else if (elemType == '-') std::cout << "(error) " << elemBody << "\n";
            else std::cout << elemLine << "\n";
        }
        break;
    }

    default:
        std::cout << firstLine << "\n";
    }
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

    std::string line;
    while (true)
    {
        std::cout << host << ":" << port << "> ";
        std::cout.flush();

        if (!std::getline(std::cin, line)) break;
        if (line.empty()) continue;
        if (line == "quit" || line == "exit") break;

        auto tokens = tokenize(line);
        if (tokens.empty()) continue;

        std::string req = encodeRESP(tokens);
        int sent = send(fd, req.c_str(), req.size(), 0);
        if (sent <= 0) { std::cerr << "Send failed\n"; break; }

        if (!readResponse(fd)) { std::cerr << "Connection closed\n"; break; }
    }

    close(fd);
    return 0;
}
