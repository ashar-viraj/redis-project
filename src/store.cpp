#include "store.h"
#include <string>
#include <stdexcept>

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

    return std::get<string>(kv[key].value);
}

long long Store::rpush(const string &key, const string &value) {
    auto itr = kv.find(key);

    if(itr == kv.end()) {
        ValueEntry entry;
        entry.value = ListType{value};

        kv[key] = move(entry);

        return 1;
    }

    // IMPORTANT
    auto *list = get_if<ListType>(&((itr->second).value));

    if(!list)
        return -1;

    list->push_back(value);

    return list->size();
}

optional<ListType> Store::lrange(const string &key, int left, int right) {
    auto itr = kv.find(key);

    ListType values;
    
    if(itr == kv.end()) 
        return values;

    auto *list = get_if<ListType>(&(itr->second.value));

    if(!list)
        return nullopt;

    int listSize = list->size();
    if(right < 0)
        right = listSize + right;
    if(left < 0)
        left = listSize + left;

    for(int i = max(0, left); i <= min(right, listSize-1); i++)
        values.push_back(list->at(i));

    return values;
}
