#include "rdb_parser.h"
#include <iostream>

using namespace std;

bool RDBParser::load(const string &filePath, Store &store) {
    ifstream in(filePath, ios::binary);

    if(!in.is_open())
        return false;

    char header[9];
    in.read(header, 9);

    if(!in || string(header, 9) != "REDIS0011")
        throw runtime_error("Invalid RDB file");

    skipMetadata(in);
    parseDatabase(in, store);

    return true;
}

uint8_t RDBParser::readByte(ifstream &in) {
    char byte;
    in.read(&byte, 1);

    if(!in)
        throw runtime_error("Unexpected end of RDB file");

    return static_cast<uint8_t>(byte);
}

uint64_t RDBParser::readLength(ifstream &in) {
    uint8_t first = readByte(in);
    uint8_t type = first >> 6;

    switch (type) {
        case 0:
            return first & 0x3F;

        case 1: {
            uint8_t second = readByte(in);
            return ((first & 0x3F) << 8) | second;
        }

        case 2: {
            uint64_t len = 0;
            for(int i = 0; i < 4; i++)
                len = (len << 8) | readByte(in);

            return len;
        }

        default:
            throw runtime_error("Special string encoding is not supported yet.");
    }
}

string RDBParser::readString(ifstream &in) {
    uint64_t length = readLength(in);

    string str(length, '\0');
    in.read(&str[0], length);

    if(!in)
        throw runtime_error("Unexpected end of RDB file while reading string");

    return str;
}

uint64_t RDBParser::readUint64LE(ifstream &in) {
    uint64_t value = 0;

    for(int i = 0; i < 8; i++)
        value |= static_cast<uint64_t>(readByte(in)) << (8 * i);

    return value;
}

uint32_t RDBParser::readUint32LE(ifstream &in) {
    uint32_t value = 0;

    for(int i = 0; i < 4; i++)
        value |= static_cast<uint32_t>(readByte(in)) << (8 * i);

    return value;
}

void RDBParser::skipMetadata(ifstream &in) {
    while(true) {
        uint8_t opcode = readByte(in);

        if(opcode == 0xFA) {
            readString(in);
            readString(in);
        } else if(opcode == 0xFE) {
            in.seekg(-1, ios::cur);
            return;
        } else
            throw runtime_error("Unexpected opcode before database");
    }
}

void RDBParser::parseDatabase(ifstream &in, Store &store) {
    uint8_t opcode = readByte(in);
    if(opcode != 0xFE)
        throw runtime_error("Expected database section");
    readLength(in);

    opcode = readByte(in);
    if(opcode != 0xFB)
        throw runtime_error("Expected database section");
    readLength(in); // Number of keys
    readLength(in); // Number of values

    while(true) {
        opcode = readByte(in);
        optional<long long> expiry = nullopt;

        if(opcode == 0xFF)
            return;


        auto nowUnixMs = chrono::duration_cast<chrono::milliseconds>(chrono::system_clock::now().time_since_epoch()).count();
        if(opcode == 0xFC) {
            expiry = static_cast<long long>(readUint64LE(in)) - nowUnixMs;
            opcode = readByte(in);
        } else if(opcode == 0xFD) {
            expiry = static_cast<long long>(readUint32LE(in)) * 1000ll - nowUnixMs;
            opcode = readByte(in);
        }

        if(opcode != 0x00)
            throw runtime_error("Only string values are supported");

        string key = readString(in);
        string value = readString(in);
        if(expiry && *expiry <= 0)
            continue;
        store.set(key, value, expiry);
    }
}