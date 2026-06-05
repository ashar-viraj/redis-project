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

using ListType = deque<string>;
using RedisData = variant<string, ListType>;

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
};