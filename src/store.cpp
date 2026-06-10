#include "store.h"
#include <string>
#include <vector>
#include <stdexcept>
#include <iostream>

// Helper functions
StreamID parseStreamID(const string &id) {
    size_t dashPos = id.find('-');

    if(dashPos == -1)
        throw runtime_error("Invalid Stream ID format");

    return {
        stoll(id.substr(0, dashPos)),
        stoll(id.substr(dashPos + 1))
    };
}

bool operator<(const StreamID &a, const StreamID &b) {
    if(a.ms != b.ms)
        return a.ms < b.ms;
    return a.seq < b.seq;
}

// Implementations

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
    lock_guard lock(storeMutex);

    auto itr = kv.find(key);

    auto currTime = chrono::steady_clock::now();
    if(itr != kv.end() && itr->second.expiry && itr->second.expiry <= currTime) {
        kv.erase(itr);
        itr = kv.end();
    }

    if(itr == kv.end()) {
        ValueEntry entry;
        entry.value = ListType{};
        kv[key] = move(entry);
        itr = kv.find(key);
    }

    auto *list = get_if<ListType>(&(itr->second.value));
    if(!list)
        return -1;

    while(!waiting[key].empty()) {
        auto waiter = waiting[key].front();
        waiting[key].pop();
        {
            lock_guard g(waiter->mtx);
            if(waiter->completed)
                continue;
            waiter->completed = true;
            waiter->poppedValue = value;
        }

        waiter->cv.notify_one();
        return 1;
    }

    list->push_back(value);
    return list->size();
}

long long Store::lpush(const string &key, const string &value) {
    lock_guard lock(storeMutex);

    auto itr = kv.find(key);

    auto currTime = chrono::steady_clock::now();
    if(itr != kv.end() && itr->second.expiry && itr->second.expiry <= currTime) {
        kv.erase(itr);
        itr = kv.end();
    }

    if(itr == kv.end()) {
        ValueEntry entry;
        entry.value = ListType{};
        kv[key] = move(entry);
        itr = kv.find(key);
    }

    auto *list = get_if<ListType>(&(itr->second.value));
    if(!list)
        return -1;

    while(!waiting[key].empty()) {
        auto waiter = waiting[key].front();
        waiting[key].pop();
        {
            lock_guard g(waiter->mtx);
            if(waiter->completed)
                continue;
            waiter->completed = true;
            waiter->poppedValue = value;
        }

        waiter->cv.notify_one();
        return 1;
    }

    list->push_front(value);
    return list->size();
}

optional<vector<string>> Store::lrange(const string &key, int left, int right) {
    auto itr = kv.find(key);

    optional<vector<string>> values = vector<string>{};

    if(itr == kv.end())
        return values;

    ListType *list = get_if<ListType>(&(itr->second.value));
    if(!list)
        throw runtime_error(
            "WRONGTYPE Operation against a key holding the wrong kind of value"
        );

    int size = (int)list->size();

    if(right < 0) right = size + right;
    if(left < 0)  left  = size + left;

    for(int i = max(0, left); i <= min(size - 1, right); i++)
        values->push_back((*list)[i]);

    return values;
}

long long Store::llen(const string &key) {
    auto itr = kv.find(key);

    if(itr == kv.end())
        return 0;

    auto *list = get_if<ListType>(&(itr->second.value));

    if(!list)
        return -1;

    return list->size();
}

optional<string> Store::lpop(const string &key) {
    auto itr = kv.find(key);

    if(itr == kv.end())
        return nullopt;

    auto *list = get_if<ListType>(&(itr->second.value));

    if(!list || list->empty())
        return nullopt;

    const string front = list->front();
    list->pop_front();

    return front;
}

optional<pair<string, string>> Store::blpop(const string &key, double timeoutSeconds) {
    shared_ptr<WaitingClient> waiter;

    {
        lock_guard lock(storeMutex);
        auto itr = kv.find(key);

        if(itr != kv.end()) {
            auto *list = get_if<ListType>(&itr->second.value);

            if(!list)
                throw runtime_error("WRONGTYPE Operation against a key holding the wrong kind of value");

            if(!list->empty()) {
                string val = list->front();

                list->pop_front();

                return {{key, val}};
            }
        }

        waiter = make_shared<WaitingClient>();
        waiting[key].push(waiter);
    }

    unique_lock lock(waiter->mtx);

    if(timeoutSeconds == 0) {
        waiter->cv.wait(lock, [&] {
            return waiter->poppedValue.has_value();
        });
    } else {
        auto timeout = chrono::milliseconds(static_cast<long long>(timeoutSeconds * 1000));
        waiter->cv.wait_for(lock, timeout, [&] {
            return waiter->completed;
        });
    }

    if(waiter->poppedValue.has_value())
        return {{key, *waiter->poppedValue}};

    waiter->completed = true;
    return nullopt;
}

string Store::type(const string &key) {
    auto itr = kv.find(key);

    if(itr == kv.end())
        return "none";

    auto currTime = chrono::steady_clock::now();
    if(itr->second.expiry && itr->second.expiry <= currTime) {
        kv.erase(itr);
        return "none";
    }

    if(get_if<string>(&itr->second.value))
        return "string";

    if(get_if<ListType>(&itr->second.value))
        return "list";

    if(get_if<StreamType>(&itr->second.value))
        return "stream";

    return "none";
}

string Store::xadd(const string &streamKey, const string &entryId, const vector<pair<string, string>> &fields) {
    StreamID newId = parseStreamID(entryId);
    if(newId.ms == 0 && newId.seq == 0)
        throw runtime_error("ERR The ID specified in XADD must be greater than 0-0");

    auto itr = kv.find(streamKey);

    auto currTime = chrono::steady_clock::now();
    if(itr != kv.end() && itr->second.expiry && itr->second.expiry <= currTime) {
        kv.erase(itr);
        itr = kv.end();
    }

    if(itr == kv.end()) {
        ValueEntry entry;
        entry.value = StreamType{};
        kv[streamKey] = move(entry);
        itr = kv.find(streamKey);
    }


    auto *stream = get_if<StreamType>(&itr->second.value);

    if(!stream)
        throw runtime_error("WRONGTYPE Operation against a key holding the wrong kind of value");

    if(!stream->empty()) {
        StreamID lastId = parseStreamID(stream->back().id);

        if(!(lastId < newId))
            throw runtime_error("ERR The ID specified in XADD is equal or smaller than the target stream top item");
    }

    stream->push_back({entryId, fields});

    return entryId;
}
