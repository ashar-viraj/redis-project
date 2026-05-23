#pragma once

#include <unordered_map>
#include <string>
#include <optional>

using namespace std;

class Store{
private:
    unordered_map<string, string> kv;
public:
    void set(const string &key, const string &value);
    optional<string> get(const string &key);
};