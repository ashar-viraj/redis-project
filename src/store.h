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

using namespace std;

struct StreamID{
    long long ms, seq;
};
struct StreamEntry {
    StreamID id;
    vector<pair<string, string>> fields;
};

using ListType = deque<string>;
using StreamType = vector<StreamEntry>;
using RedisData = variant<string, ListType, StreamType>;

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

class Store{
private:
    map<string, ValueEntry> kv;
    map<string, queue<shared_ptr<WaitingClient>>> waiting;
    mutex storeMutex;
public:
    void set(const string &key, const string &value, optional<long long> px);
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
};