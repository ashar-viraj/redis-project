#include "resp_parser.h"
#include <stdexcept>
#include <string>

#include <iostream>

using namespace std;

string RESPParser::arrayToString(char buffer[])
{
    string str = "";
    for (int i = 0; buffer[i] != '\0'; i++)
        str += buffer[i];

    return str;
}

// NEW SIGNATURE: takes the accumulated stream buffer and hands back how many bytes were consumed to produce this one RESPValue. The caller is responsible for erasing exactly that many bytes from its pending buffer before calling parse() again for the next command in the stream.
RESPValue RESPParser::parse(const string &buffer, size_t &bytesConsumed, size_t start)
{
    int idx = static_cast<int>(start);
    RESPValue value = parseValue(buffer, idx);
    bytesConsumed = static_cast<size_t>(idx) - start;
    return value;
}

RESPValue RESPParser::parseValue(const string &buffer, int &idx)
{
    if(idx >= (int)buffer.size())
        throw runtime_error("Incomplete RESP message");
    switch (buffer[idx])
    {
    case '+':
        return parseSimpleString(buffer, idx);

    case '-':
        return parseError(buffer, idx);

    case ':':
        return parseInteger(buffer, idx);

    case '$':
        return parseBulkString(buffer, idx);

    case '*':
        return parseArray(buffer, idx);

    default:
        throw runtime_error("Unknow RESP type.");
    }

    throw runtime_error("Unknown Type.");
}

// readLine now throws "Incomplete RESP message" if it runs off the end of
// the buffer without finding a terminating \r\n, instead of silently
// returning a truncated line. This is what lets the caller distinguish
// "not enough bytes yet, wait for more recv()" from a real parse error.
string RESPParser::readLine(const string &buffer, int &idx)
{
    string result;

    int bufferSize = buffer.size();
    int start = idx;
    while (idx < bufferSize && buffer[idx] != '\r')
        result += buffer[idx++];

    // Either we hit the end of the buffer without finding '\r', or we found
    // '\r' but there isn't a following '\n' yet -> the line isn't fully
    // buffered. Both cases mean "come back later, we need more bytes".
    if (idx >= bufferSize || idx + 1 >= bufferSize)
    {
        idx = start;
        throw runtime_error("Incomplete RESP message");
    }

    idx += 2;
    return result;
}

RESPValue RESPParser::parseSimpleString(const string &buffer, int &idx)
{
    idx++;

    return {readLine(buffer, idx), '+'};
}

RESPValue RESPParser::parseError(const string &buffer, int &idx)
{
    idx++;

    return {readLine(buffer, idx), '-'};
}

RESPValue RESPParser::parseInteger(const string &buffer, int &idx)
{
    idx++;

    long long val = stoll(readLine(buffer, idx));

    return {val, ':'};
}

RESPValue RESPParser::parseBulkString(const string &buffer, int &idx)
{
    int start = idx;
    idx++;

    int strLen = stoi(readLine(buffer, idx));

    // Make sure the full body PLUS the trailing \r\n is actually present
    // before consuming it. Previously substr() would silently truncate if
    // the body hadn't fully arrived yet, corrupting the parse.
    if (idx + strLen + 2 > (int)buffer.size())
    {
        idx = start;
        throw runtime_error("Incomplete RESP message");
    }

    string str = buffer.substr(idx, strLen);

    idx += strLen;

    if (buffer[idx] != '\r' || buffer[idx + 1] != '\n')
        throw runtime_error("Malformed bulk string");

    idx += 2;

    return {str, '$'};
}

RESPValue RESPParser::parseArray(const string &buffer, int &idx)
{
    int start = idx;
    idx++;

    int arraySize = stoi(readLine(buffer, idx));
    RESPArray array;

    try {
        for (int i = 0; i < arraySize; i++)
            array.push_back(parseValue(buffer, idx));
    } catch (const runtime_error &e) {
        // If any element inside the array is incomplete, the whole array is
        // incomplete. Reset idx back to the start of this array so the
        // caller's pending buffer is left untouched and the entire array is
        // re-parsed once more bytes arrive.
        idx = start;
        throw;
    }

    return {array, '*'};
}