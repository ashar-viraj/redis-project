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

    return std::get<string>(kv[key].value);
}

long long Store::rpush(const string &key, const string &value) {
    auto itr = kv.find(key);

    if(itr == kv.end()) {
        ValueEntry entry;
        entry.start = 0, entry.end = 0;
        entry.value = ListType{{0, value}};

        kv[key] = move(entry);

        return 1;
    }

    // IMPORTANT
    auto *list = get_if<ListType>(&((itr->second).value));

    if(!list)
        return -1;

    (*itr->second.end)++;
    (*list)[*itr->second.end] = value;

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

    int startIdx = *itr->second.start;
    int endIdx = *itr->second.end;
    
    int listSize = list->size();

    left += startIdx;
    right += startIdx;

    if(right < 0)
        right = listSize + right;
    if(left < 0)
        left = listSize + left;

    std::cout << left << ' ' << right << ' ' << startIdx << ' ' << endIdx << endl;
    

    for(int i = max(startIdx, left); i <= min(endIdx, right); i++)
        (*values).push_back((*list)[i]);
        
    return values;
}
