#pragma once

#include <string>
#include <fstream>
#include "../store.h"

using namespace std;

class RDBParser {
public:
    bool load(const string &filePath, Store &store);

private:
    uint8_t readByte(ifstream &in);
    uint64_t readLength(ifstream &in);
    string readString(ifstream &in);
    uint64_t readUint64LE(ifstream &in);
    uint32_t readUint32LE(ifstream &in);
    void skipMetadata(ifstream &in);
    void parseDatabase(ifstream &in, Store &store);
};