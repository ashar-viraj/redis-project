#include "store.h"

void Store::set(const string &key, const string &value) {
    kv[key] = value;
}

optional<string> Store::get(const string &key) {
    if(kv.find(key) != kv.end())
        return kv[key];

    return nullopt;
}