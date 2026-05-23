#pragma once

#include <unordered_map>
#include <string>
#include <optional>
#include <chrono>

using namespace std;

struct ValueEntry{
    string value;
    // IMPORTANT
    optional<chrono::steady_clock::time_point> expiry;
};

class Store{
private:
    unordered_map<string, ValueEntry> kv;
public:
    void set(const string &key, const string &value, optional<long long> px);
    optional<string> get(const string &key);
};