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

RESPValue RESPParser::parse(char buffer[])
{
    int idx = 0;
    string bufferStr = arrayToString(buffer);
    // cout << "bufferStr: " << bufferStr << endl;
    return parseValue(bufferStr, idx);
}

RESPValue RESPParser::parseValue(const string &buffer, int &idx)
{
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

string RESPParser::readLine(const string &buffer, int &idx)
{
    string result;

    int bufferSize = buffer.size();
    while (idx < bufferSize && buffer[idx] != '\r')
        result += buffer[idx++];

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
    idx++;
    
    int strLen = stoi(readLine(buffer, idx));
    
    string str = buffer.substr(idx, strLen);
    
    idx += strLen;
    
    if(buffer[idx] != '\r' || buffer[idx+1] != '\n') {
        // cout << "RE MBS: " << (buffer[idx] != '\r') << ' ' << (buffer[idx+1] != '\n') << (int)buffer[idx+1] << endl;
        throw runtime_error("Malformed bulk string");
    }
        
    idx += 2;

    return {str, '$'};
}

RESPValue RESPParser::parseArray(const string &buffer, int &idx)
{
    idx++;

    int arraySize = stoi(readLine(buffer, idx));
    RESPArray array;

    // cout << "array size: " << arraySize << endl;
    
    for (int i = 0; i < arraySize; i++) {
        // cout << "Parsing array " << idx << ' ' << buffer[idx] << endl;
        array.push_back(parseValue(buffer, idx));
    }

    return {array, '*'};
}