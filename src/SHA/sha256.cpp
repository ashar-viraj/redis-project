#include "./sha256.h"
#include <openssl/sha.h>
#include <sstream>
#include <iomanip>

string sha256(const string &txt) {
    unsigned char hash[SHA256_DIGEST_LENGTH];
    SHA256(
        reinterpret_cast<const unsigned char*>(txt.data()),
        txt.size(),
        hash
    );

    stringstream ss;
    ss << hex << setfill('0');

    for(unsigned char c : hash)
        ss << setw(2) << (int)c;

    return ss.str();
}