#include "store.h"

void Store::set(const string &key, const string &value, optional<long long> px) {
    ValueEntry entry;

    entry.value = value;

    if(px)
        entry.expiry = chrono::steady_clock::now() + chrono::milliseconds(*px);

    kv[key] = entry;
}

optional<string> Store::get(const string &key) {
    if(kv.find(key) == kv.end())
        return nullopt;

    auto now = chrono::steady_clock::now();

    if(kv[key].expiry && kv[key].expiry <= now) {
        kv.erase(key);

        return nullopt;
    }

    return kv[key].value;
}