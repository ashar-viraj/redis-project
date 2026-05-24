#include "store.h"
#include <string>
#include <vector>
#include <stdexcept>
#include <iostream>

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

    auto* str = get_if<string>(&kv[key].value);
    if(!str)
        return nullopt;
    return *str;
}

long long Store::rpush(const string &key, const string &value) {
    auto itr = kv.find(key);

    if(itr == kv.end()) {
        ValueEntry entry;
        entry.value = ListType{value};
        kv[key] = move(entry);
        return 1;
    }

    auto *list = get_if<ListType>(&(itr->second.value));
    if(!list)
        return -1;

    list->push_back(value);
    return list->size();
}

long long Store::lpush(const string &key, const string &value) {
    auto itr = kv.find(key);

    if(itr == kv.end()) {
        ValueEntry entry;
        entry.value = ListType{value};
        kv[key] = move(entry);
        return 1;
    }

    auto *list = get_if<ListType>(&(itr->second.value));
    if(!list)
        return -1;

    list->push_front(value);
    return list->size();
}

optional<vector<string>> Store::lrange(const string &key, int left, int right) {
    auto itr = kv.find(key);

    optional<vector<string>> values = vector<string>{};

    if(itr == kv.end())
        return values;

    auto *list = get_if<ListType>(&(itr->second.value));
    if(!list)
        return nullopt;

    int size = (int)list->size();

    if(right < 0) right = size + right;
    if(left < 0)  left  = size + left;

    for(int i = max(0, left); i <= min(size - 1, right); i++)
        values->push_back((*list)[i]);

    return values;
}
