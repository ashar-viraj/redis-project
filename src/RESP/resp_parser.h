#pragma once

#include <string>
#include <vector>
#include <variant>

struct RESPValue;

using namespace std;
using RESPArray = vector<RESPValue>;

struct RESPValue
{
    variant<string, long long, RESPArray, nullptr_t> value;
    char type;
};

class RESPParser
{
public:
    RESPValue parse(char buffer[]);

private:
    RESPValue parseValue(const string &buffer, int &idx);
    RESPValue parseSimpleString(const string &buffer, int &idx);
    RESPValue parseError(const string &buffer, int &idx);
    RESPValue parseInteger(const string &buffer, int &idx);
    RESPValue parseBulkString(const string &buffer, int &idx);
    RESPValue parseArray(const string &buffer, int &idx);
    string readLine(const string &buffer, int &idx);
    string arrayToString(char buffer[]);
};
