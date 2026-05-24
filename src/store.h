#pragma once

#include <unordered_map>
#include <string>
#include <optional>
#include <chrono>
#include <vector>
#include <variant>

using namespace std;

using ListType = vector<string>;
using RedisData = variant<string, ListType>;

struct ValueEntry{
    RedisData value;
    // IMPORTANT
    optional<chrono::steady_clock::time_point> expiry;
};

class Store{
private:
    unordered_map<string, ValueEntry> kv;
public:
    void set(const string &key, const string &value, optional<long long> px);
    optional<string> get(const string &key);
    long long rpush(const string &key, const string &value);
};