#pragma once

#include <map>
#include <string>
#include <optional>
#include <chrono>
#include <deque>
#include <queue>
#include <variant>
#include <condition_variable>
#include <mutex>
#include <memory>
#include <vector>
#include <set>

using namespace std;

struct StreamID{
    long long ms, seq;
};
struct StreamEntry {
    StreamID id;
    vector<pair<string, string>> fields;
};

struct SortedSetEntry {
    string member;
    double score;
};

using ListType = deque<string>;
using StreamType = vector<StreamEntry>;
using SortedSetType = vector<SortedSetEntry>;
using RedisData = variant<string, ListType, StreamType, SortedSetType>;

StreamID parseStreamID(const string &id);
bool operator<(const StreamID &a, const StreamID &b);
bool operator<=(const StreamID &a, const StreamID &b);
bool operator>=(const StreamID &a, const StreamID &b);
StreamID parseRangeID(const string &id, bool isStart);
bool isInvalidEntryId(const string &id);
string streamIDToString(StreamID id);
bool isPartialId(const string &id);
StreamID generatePartialID(const StreamType &stream, long long ms);
StreamID generateAutoID(const StreamType &stream);
bool operator<(const SortedSetEntry &a, const SortedSetEntry &b);
struct ValueEntry{
    RedisData value;
    optional<chrono::steady_clock::time_point> expiry;
};

struct WaitingClient {
    mutex mtx;
    condition_variable cv;
    optional<string> poppedValue;
    bool completed = false;
};

struct StreamWaitingClient {
    mutex mtx;
    condition_variable cv;
    bool completed = false;
};

class Store{
private:
    using Iterator = map<string, ValueEntry>::iterator;

    map<string, ValueEntry> kv;
    map<string, queue<shared_ptr<WaitingClient>>> waiting;
    map<string, deque<shared_ptr<StreamWaitingClient>>> streamWaiting;
    mutex storeMutex;
    map<string, uint64_t> keyVersion;
    map<string, set<int>> channelSubscribers;
    map<int, set<string>> clientSubscriptions;

public:
    Iterator findValidKey(const string& key);
    void setValue(const string &key, const string &value, optional<long long> px);
    optional<string> get(const string &key);
    long long rpush(const string &key, const string &value);
    long long lpush(const string &key, const string &value);
    optional<vector<string>> lrange(const string &key, int left, int right);
    long long llen(const string &key);
    optional<string> lpop(const string &key);
    optional<pair<string, string>> blpop(const string &key, double timeoutSeconds);

    string type(const string &key);
    string xadd(const string &streamKey, const string &entryId, const vector<pair<string, string>> &fields);
    optional<StreamType> xrange(const string &key, const string &start, const string &end);
    optional<StreamType> xread(const string &key, const string &id);
    optional<vector<pair<string, StreamType>>> xreadBlocking(const vector<pair<string, string>> &streams, long long timeoutMs);
    optional<long long> incr(const string &key);
    void markKeyAsModified(const string &key);
    uint64_t getKeyVersion(const string &key);
    vector<string> getkeys();

    long long subscribe(int clinetFd, const string &channel);
    long long unsubscribe(int clientFd, const string &channel);
    vector<int> getSubscribers(const string &channel);

    long long zadd(const string &key, double score, const string &member);
    optional<long long> zrank(const string &key, const string &member);
    optional<vector<string>> zrange(const string &key, int start, int end);
    long long zcard(const string &key);
    optional<string> zscore(const string &key, const string &member);
    long long zrem(const string &key, const string &member);
    optional<SortedSetType> getSortedSet(const string &key);
};
