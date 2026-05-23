#pragma once

#include "resp_parser.h"

class RESPSerializer{
public:
    string serialize(const RESPValue &value);

private:
    string simpleString(const string &str);
    string error(const string &str);
    string integer(long long num);
    string bulkString(const RESPValue &value);
    string array(const RESPArray &arr);
};