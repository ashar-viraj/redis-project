#include "resp_serializer.h"
#include <stdexcept>
#include <iostream>

using namespace std;

string RESPSerializer::serialize(const RESPValue &value)
{
    switch (value.type)
    {
    case '+':
        return simpleString(get<string>(value.value));

    case '-':
        return error(get<string>(value.value));

    case ':':
        return integer(get<long long>(value.value));

    case '$':
        return bulkString(value);
        // return bulkString(get<string>(value.value));

    case '*': {
        if(!holds_alternative<RESPArray>(value.value))
            return "*-1\r\n";
        return array(get<RESPArray>(value.value));
    }

    default:
        throw runtime_error("Unknown type in Serializing.");
    }
}

string RESPSerializer::simpleString(const string &str)
{
    return "+" + str + "\r\n";
}

string RESPSerializer::error(const string &str)
{
    return "-" + str + "\r\n";
}

string RESPSerializer::integer(long long num)
{
    return ":" + to_string(num) + "\r\n";
}

string RESPSerializer::bulkString(const RESPValue &value)
{
    if(holds_alternative<nullptr_t>(value.value))
        return "$-1\r\n";

    string str = get<string>(value.value);

    return "$" + to_string(str.size()) + "\r\n" + str + "\r\n";
}

string RESPSerializer::array(const RESPArray &arr)
{
    string result = "*" + to_string(arr.size()) + "\r\n";

    for (auto &e : arr)
        result += serialize(e);

    return result;
}