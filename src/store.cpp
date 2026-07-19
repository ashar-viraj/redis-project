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

bool operator<=(const StreamID &a, const StreamID &b) {
    return !(b < a);
}

bool operator>=(const StreamID &a, const StreamID &b) {
    return !(a < b);
}

StreamID parseRangeID(const string &id, bool isStart) {
    if(id == "-")
        return {0, 0};

    if(id == "+")
        return {LLONG_MAX, LLONG_MAX};

    size_t dash = id.find('-');

    if(dash == string::npos) {
        return {
            stoll(id),
            isStart ? 0 : LLONG_MAX
        };
    }

    return parseStreamID(id);
}

bool isInvalidEntryId(const string &id) {
    if(id == "*")
        return false;
    int dashPos = id.find('-');
    if(dashPos == 0 || dashPos == id.size()-1 || dashPos == -1)
        return true;
    for(int i = 0; i < dashPos; i++)
        if(id[i] < '0' || id[i] > '9')
            return true;
    if(dashPos == id.size()-2 && id.back() == '*')
        return false;
    for(int i = dashPos + 1; i < id.size(); i++)
        if(id[i] < '0' || id[i] > '9')
            return true;

    return false;
}

string streamIDToString(StreamID id) {
    return to_string(id.ms) + "-" + to_string(id.seq);
}

bool isPartialId(const string &id) {
    size_t dashPos = id.find('-');
    return dashPos != -1 && dashPos == id.size() - 2 && id.back() == '*';
}

bool isInteger(string s) {
    if(s.empty())
        return true;
    int i = 0;
    if(s[i] == '-' || s[i] == '+')
        i++;
    while(i < s.size()) {
        if(s[i] < '0' || s[i] > '9')
            return false;
        i++;
    }

    return true;
}

StreamID generatePartialID(const StreamType &stream, long long ms) {
    long long seq;

    if(ms == 0)
        seq = 1;
    else
        seq = 0;

    for(auto itr = stream.rbegin(); itr != stream.rend(); itr++) {
        if(itr->id.ms == ms) {
            seq = itr->id.seq + 1;
            break;
        }
    }

    return {ms, seq};
}

StreamID generateAutoID(const StreamType &stream){
    long long ms = chrono::duration_cast<chrono::milliseconds>(
        chrono::system_clock::now().time_since_epoch()
    ).count();

    if(stream.empty())
        return {ms, 0};

    const StreamID &lastId = stream.back().id;

    if(ms > lastId.ms)
        return {ms, 0};

    return {lastId.ms, lastId.seq + 1};
}

Store::Iterator Store::findValidKey(const string& key) {
    auto itr = kv.find(key);
    if (itr == kv.end()) {
        return itr;
    }

    if (itr->second.expiry && itr->second.expiry <= chrono::steady_clock::now()) {
        kv.erase(itr);
        return kv.end();
    }

    return itr;
}

bool operator<(const SortedSetEntry &a, const SortedSetEntry &b) {
    if(a.score != b.score)
        return a.score < b.score;

    return a.member < b.member;
}

// Implementations

void Store::setValue(const string &key, const string &value, optional<long long> px) {
    lock_guard lock(storeMutex);

    ValueEntry entry;

    entry.value = value;

    if(px)
        entry.expiry = chrono::steady_clock::now() + chrono::milliseconds(*px);

    kv[key] = entry;
}

optional<string> Store::get(const string &key) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);
    if (itr == kv.end())
        return nullopt;

    auto* str = get_if<string>(&itr->second.value);
    if(!str)
        return nullopt;
    return *str;
}

long long Store::rpush(const string &key, const string &value) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);
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

    auto itr = findValidKey(key);

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
    lock_guard lock(storeMutex);

    auto itr = kv.find(key);

    optional<vector<string>> values = vector<string>{};

    if(itr == kv.end())
        return values;

    ListType *list = get_if<ListType>(&(itr->second.value));
    if(!list)
        throw runtime_error("WRONGTYPE Operation against a key holding the wrong kind of value");

    int size = (int)list->size();

    if(right < 0) right = size + right;
    if(left < 0)  left  = size + left;

    for(int i = max(0, left); i <= min(size - 1, right); i++)
        values->push_back((*list)[i]);

    return values;
}

long long Store::llen(const string &key) {
    lock_guard lock(storeMutex);

    auto itr = kv.find(key);

    if(itr == kv.end())
        return 0;

    auto *list = get_if<ListType>(&(itr->second.value));

    if(!list)
        return -1;

    return list->size();
}

optional<string> Store::lpop(const string &key) {
    lock_guard lock(storeMutex);

    auto itr = kv.find(key);

    if(itr == kv.end())
        return nullopt;

    auto *list = get_if<ListType>(&(itr->second.value));

    if(!list || list->empty())
        return nullopt;

    const string front = list->front();
    list->pop_front();
    markKeyAsModified(key);

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

                markKeyAsModified(key);
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

    if(waiter->poppedValue.has_value()) {
        markKeyAsModified(key);
        return {{key, *waiter->poppedValue}};
    }

    waiter->completed = true;
    return nullopt;
}

string Store::type(const string &key) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);

    if (itr == kv.end())
        return "none";

    if(get_if<string>(&itr->second.value))
        return "string";

    if(get_if<ListType>(&itr->second.value))
        return "list";

    if(get_if<StreamType>(&itr->second.value))
        return "stream";

    if(get_if<SortedSetType>(&itr->second.value))
        return "zset";

    return "none";
}

string Store::xadd(const string &streamKey, const string &entryId, const vector<pair<string, string>> &fields) {
    lock_guard lock(storeMutex);

    if(isInvalidEntryId(entryId))
        throw runtime_error("ERR wrong type of argument in id. Should be of format <num>-<num>, *, <num>-*.");

    auto itr = findValidKey(streamKey);

    if(itr == kv.end()) {
        ValueEntry entry;
        entry.value = StreamType{};
        kv[streamKey] = move(entry);
        itr = kv.find(streamKey);
    }

    auto *stream = get_if<StreamType>(&itr->second.value);
    if(!stream)
        throw runtime_error("WRONGTYPE Operation against a key holding the wrong kind of value");

    StreamID newId;

    if(entryId == "*") {
        newId = generateAutoID(*stream);
    }
    else if(isPartialId(entryId)) {
        long long ms = stoll(entryId.substr(0, entryId.find('-')));
        newId = generatePartialID(*stream, ms);
    } else {
        newId = parseStreamID(entryId);
    }

    if(newId.ms == 0 && newId.seq == 0)
        throw runtime_error("ERR The ID specified in XADD must be greater than 0-0");

    if(!stream->empty()) {
        StreamID lastId = stream->back().id;

        if(!(lastId < newId))
            throw runtime_error("ERR The ID specified in XADD is equal or smaller than the target stream top item");
    }

    markKeyAsModified(streamKey);
    stream->push_back({newId, fields});

    while(!streamWaiting[streamKey].empty()) {
        auto waiter = streamWaiting[streamKey].front();
        streamWaiting[streamKey].pop_front();

        {
            lock_guard g(waiter->mtx);
            if(waiter->completed)
                continue;
            waiter->completed = true;
        }

        waiter->cv.notify_one();
    }

    if(streamWaiting[streamKey].empty())
        streamWaiting.erase(streamKey);

    return streamIDToString(newId);
}

optional<StreamType> Store::xrange(const string &key, const string &startStr, const string &endStr) {
    lock_guard lock(storeMutex);

    auto itr = kv.find(key);

    if(itr == kv.end())
        return vector<StreamEntry>{};

    auto *stream = get_if<StreamType>(&itr->second.value);

    if(!stream)
        return nullopt;

    StreamID start = parseRangeID(startStr, true), end = parseRangeID(endStr, false);

    StreamType result;

    auto startItr = lower_bound(stream->begin(), stream->end(), start, [](const StreamEntry &entry, const StreamID &id) {
        return entry.id < id;
    });

    for(auto itr = startItr; itr != stream->end(); itr++) {
        if(end < itr->id)
            break;

        result.push_back(*itr);
    }

    return result;
}

optional<StreamType> Store::xread(const string &key, const string &idStr) {
    lock_guard lock(storeMutex);

    auto itr = kv.find(key);

    if(itr == kv.end())
        return nullopt;

    auto *stream = get_if<StreamType>(&itr->second.value);

    if(!stream)
        throw runtime_error("WRONGTYPE Operation against a key holding the wrong kind of value");

    StreamID id = parseRangeID(idStr, false);

    auto startItr = upper_bound(stream->begin(), stream->end(), id,
    [](const StreamID &id, const StreamEntry &entry){
        return id < entry.id;
    });

    StreamType result(startItr, stream->end());

    return result;
}

optional<vector<pair<string, StreamType>>> Store::xreadBlocking(const vector<pair<string, string>> &streams, long long timeoutMs) {
    shared_ptr<StreamWaitingClient> waiter;
    vector<pair<string, string>> resolvedStreams;

    auto collectAvailable = [&]() {
        vector<pair<string, StreamType>> response;

        for(const auto &[key, idStr] : resolvedStreams) {
            auto itr = kv.find(key);

            if(itr == kv.end())
                continue;

            auto *stream = get_if<StreamType>(&itr->second.value);

            if(!stream)
                throw runtime_error("WRONGTYPE Operation against a key holding the wrong kind of value");

            StreamID id = parseRangeID(idStr, false);

            auto startItr = upper_bound(stream->begin(), stream->end(), id,
            [](const StreamID &id, const StreamEntry &entry){
                return id < entry.id;
            });

            StreamType result(startItr, stream->end());

            if(!result.empty())
                response.push_back({key, result});
        }

        return response;
    };

    {
        lock_guard lock(storeMutex);

        for(const auto &[key, idStr] : streams) {
            if(idStr != "$") {
                resolvedStreams.push_back({key, idStr});
                continue;
            }

            auto itr = kv.find(key);

            if(itr == kv.end()) {
                resolvedStreams.push_back({key, "0-0"});
                continue;
            }

            auto *stream = get_if<StreamType>(&itr->second.value);

            if(!stream)
                throw runtime_error("WRONGTYPE Operation against a key holding the wrong kind of value");

            if(stream->empty())
                resolvedStreams.push_back({key, "0-0"});
            else
                resolvedStreams.push_back({key, streamIDToString(stream->back().id)});
        }

        vector<pair<string, StreamType>> available = collectAvailable();
        if(!available.empty())
            return available;

        waiter = make_shared<StreamWaitingClient>();

        for(const auto &[key, _] : resolvedStreams)
            streamWaiting[key].push_back(waiter);
    }

    unique_lock lock(waiter->mtx);

    if(timeoutMs == 0) {
        waiter->cv.wait(lock, [&] {
            return waiter->completed;
        });
    } else {
        waiter->cv.wait_for(lock, chrono::milliseconds(timeoutMs), [&] {
            return waiter->completed;
        });
    }

    bool timedOut = !waiter->completed;
    waiter->completed = true;

    lock.unlock();

    lock_guard storeLock(storeMutex);

    for(const auto &[key, _] : resolvedStreams) {
        auto waitersItr = streamWaiting.find(key);
        if(waitersItr == streamWaiting.end())
            continue;

        auto &waiters = waitersItr->second;
        for(auto itr = waiters.begin(); itr != waiters.end();) {
            if(*itr == waiter)
                itr = waiters.erase(itr);
            else
                itr++;
        }

        if(waiters.empty())
            streamWaiting.erase(waitersItr);
    }

    if(timedOut)
        return nullopt;

    vector<pair<string, StreamType>> available = collectAvailable();

    if(available.empty())
        return nullopt;

    return available;
}

void Store::markKeyAsModified(const string &key) {
    keyVersion[key]++;
}

uint64_t Store::getKeyVersion(const string &key) {
    return keyVersion[key];
}

optional<long long> Store::incr(const string &key) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);

    if(itr == kv.end()) {
        ValueEntry entry;
        entry.value = "1";
        entry.expiry = nullopt;

        markKeyAsModified(key);
        kv[key] = entry;
        return 1;
    }

    try {
        auto *oldValuePtr = get_if<string>(&itr->second.value);

        if(!oldValuePtr)
            throw runtime_error("WRONGTYPE Operation against a key holding the wrong kind of value");
        if(!isInteger(*oldValuePtr))
            throw runtime_error("ERR value is not an integer or out of range");

        long long oldValue = stoll(*oldValuePtr);
        long long newValue = oldValue+1;
        if(newValue < oldValue)
            throw runtime_error("ERR value is not an integer or out of range");

        *get_if<string>(&itr->second.value) = to_string(newValue);
        markKeyAsModified(key);
        return newValue;
    } catch (const invalid_argument&) {
        return nullopt;
    } catch (const out_of_range&) {
        return nullopt;
    }

    return nullopt;
}

vector<string> Store::getkeys() {
    lock_guard lock(storeMutex);
    vector<string> keys;
    for(auto &[key, _] : kv)
        keys.push_back(key);
    return keys;
}

long long Store::subscribe(int clientFd, const string &channel) {
    lock_guard lock(storeMutex);

    channelSubscribers[channel].insert(clientFd);
    clientSubscriptions[clientFd].insert(channel);

    return clientSubscriptions[clientFd].size();
}

long long Store::unsubscribe(int clientFd, const string &channel) {
    lock_guard lock(storeMutex);

    channelSubscribers[channel].erase(clientFd);
    clientSubscriptions[clientFd].erase(channel);

    if(channelSubscribers[channel].empty())
        channelSubscribers.erase(channel);
    if(clientSubscriptions[clientFd].empty())
    {
        clientSubscriptions.erase(clientFd);
        return 0ll;
    }

    return clientSubscriptions[clientFd].size();
}

vector<int> Store::getSubscribers(const string &channel) {
    lock_guard lock(storeMutex);

    vector<int> subscribers;
    auto itr = channelSubscribers.find(channel);

    if(itr == channelSubscribers.end())
        return subscribers;

    subscribers.reserve(itr->second.size());
    for(auto &sub : itr->second)
        subscribers.push_back(sub);

    return subscribers;
}

long long Store::zadd(const string &key, double score, const string &member) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);

    if(itr == kv.end()) {
        ValueEntry entry;
        entry.value = SortedSetType();
        kv[key] = move(entry);
        itr = kv.find(key);
    }

    auto *zset = get_if<SortedSetType>(&itr->second.value);

    if(!zset)
        return -1;

    auto itrMember = find_if(zset->begin(),
                            zset->end(),
                            [&](const SortedSetEntry &entry) {
                                return entry.member == member;
                            }
                        );

    if(itrMember != zset->end()) {
        SortedSetEntry updated = *itrMember;
        zset->erase(itrMember);

        updated.score = score;
        auto pos = lower_bound(zset->begin(), zset->end(), updated);

        zset->insert(pos, updated);

        return 0;
    }

    SortedSetEntry entry{member, score};

    auto pos = lower_bound(zset->begin(), zset->end(), entry);

    zset->insert(pos, entry);

    return 1;
}

optional<long long> Store::zrank(const string &key, const string &member) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);

    if(itr == kv.end())
        return nullopt;

    auto *zset = get_if<SortedSetType>(&itr->second.value);

    if(!zset)
        throw runtime_error("WRONGTYPE Operation against a key holding the wrong kind of value");

    for(int i = 0; i < zset->size(); i++) {
        if((*zset)[i].member == member) {
            return i;
        }
    }

    return nullopt;
}

optional<vector<string>> Store::zrange(const string &key, int start, int end) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);

    if(itr == kv.end())
        return {};

    auto *zset = get_if<SortedSetType>(&itr->second.value);

    if(!zset)
        return nullopt;

    vector<string> members;

    int size = (int)zset->size();

    if(start < 0) start = size + start;
    if(end < 0) end  = size + end;

    cout << "Iterating in " << start << ' ' << end << endl;

    for(int i = max(0, start); i <= min(size - 1, end); i++) {
        cout << (*zset)[i].member << ' ' << (*zset)[i].score << endl;
        members.push_back((*zset)[i].member);
    }

    return members;
}

long long Store::zcard(const string &key) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);

    if(itr == kv.end())
        return 0;

    auto *zset = get_if<SortedSetType>(&itr->second.value);

    if(!zset)
        return 0;

    return zset->size();
}

optional<string> Store::zscore(const string &key, const string &member) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);

    if(itr == kv.end())
        return nullopt;

    auto *zset = get_if<SortedSetType>(&itr->second.value);

    if(!zset)
        return nullopt;

    string score;
    for(auto &elem : *zset)
        if(elem.member == member)
            score = to_string(elem.score);

    if(score.size() == 0)
        return nullopt;

    while(score.back() == '0')
        score.pop_back();

    while(score.back() == '.')
        score.pop_back();

    return score;
}

long long Store::zrem(const string &key, const string &member) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);

    if(itr == kv.end())
        return 0;

    auto *zset = get_if<SortedSetType>(&itr->second.value);

    if(!zset)
        return 0;

    auto itrMember = find_if(zset->begin(),
                            zset->end(),
                            [&](const SortedSetEntry &entry) {
                                return entry.member == member;
                            }
                        );

    if(itrMember != zset->end()) {
        zset->erase(itrMember);
        return 1;
    }

    return 0;
}

optional<SortedSetType> Store::getSortedSet(const string &key) {
    lock_guard lock(storeMutex);

    auto itr = findValidKey(key);

    if(itr == kv.end())
        return SortedSetType{};

    auto *zset = get_if<SortedSetType>(&itr->second.value);

    if(!zset)
        return nullopt;

    return *zset;
}
