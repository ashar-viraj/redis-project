#pragma once

#include <map>
#include <string>
#include <optional>
#include <chrono>
#include <deque>
#include <variant>

using namespace std;

using ListType = deque<string>;
using RedisData = variant<string, ListType>;

struct ValueEntry{
    RedisData value;
    optional<chrono::steady_clock::time_point> expiry;
};

class Store{
private:
    map<string, ValueEntry> kv;
public:
    void set(const string &key, const string &value, optional<long long> px);
    optional<string> get(const string &key);
    long long rpush(const string &key, const string &value);
    long long lpush(const string &key, const string &value);
    optional<vector<string>> lrange(const string &key, int left, int right);
};