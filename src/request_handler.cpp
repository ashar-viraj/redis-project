#include "request_handler.h"
#include "store.h"
#include <stdexcept>
#include <iostream>

using namespace std;

RequestHandler::RequestHandler(Store &s) : store(s){}

RESPValue RequestHandler::handle(const RESPValue &req) {
    // cout << "Handling Request\n";
    if(req.type != '*')
        throw runtime_error("Command must be array");

    RESPArray arr = get<RESPArray>(req.value);

    if(arr.empty()) 
        throw runtime_error("Empty command");

    string cmd = get<string>(arr[0].value);

    for(auto &e : cmd)
        e = toupper(e);

    // cout << "cmd : " << cmd << endl;

    if(cmd == "PING")
        return handlePing();

    if(cmd == "ECHO")
        return handleEcho(arr);

    if(cmd == "SET")
        return handleSet(arr);

    if(cmd == "GET")
        return handleGet(arr);

    if(cmd == "RPUSH")
        return handleRpush(arr);

    if(cmd == "LPUSH")
        return handleLpush(arr);
        

    if(cmd == "LRANGE")
        return handleLrange(arr);

    return {"ERR unkown command", '-'};
}

RESPValue RequestHandler::handlePing(){
    return {"PONG", '+'};
}

RESPValue RequestHandler::handleEcho(const RESPArray &arr) {
    if(arr.size() != 2)
        return {"ERR wrong number of arguements", '-'};

    return {get<string>(arr[1].value), '$'};
}

RESPValue RequestHandler::handleSet(const RESPArray &arr) {
    if(arr.size() != 3 && arr.size() != 5)
        return {"ERR wrong number of arguments.", '-'};

    optional<long long> px;

    const string key = get<string>(arr[1].value);
    const string value = get<string>(arr[2].value);

    if(arr.size() == 5) {
        string option = get<string>(arr[3].value);
        for(auto &e : option) e = toupper(e);
        if(option == "PX")
            px = stoll(get<string>(arr[4].value));
        else if(option == "EX")
            px = stoll(get<string>(arr[4].value)) * 1000;
        else
            return {"ERR Unsupported option.", '-'};
    }

    store.set(key, value, px);

    return {"OK", '+'};
}

RESPValue RequestHandler::handleGet(const RESPArray &arr) {
    if(arr.size() != 2)
        return {"ERR wrong number of arguments.", '-'};

    string key = get<string>(arr[1].value);

    optional<string> value = store.get(key);

    if(value.has_value())
        return {value.value(), '$'};

    return {nullptr, '$'};
}

RESPValue RequestHandler::handleRpush(const RESPArray &arr) {
    if(arr.size() < 3)
        return {"ERR wrong number of arguments.", '-'};

    long long size;
    const string key = get<string>(arr[1].value);

    for(int i = 2; i < arr.size(); i++) {
        const string value = get<string>(arr[i].value);
        size = store.rpush(key, value);

        if(size == -1)
            return {"WRONGTYPE Operation against a key holding the wrong kind of value", '-'};
    }

    return {size, ':'};
}

RESPValue RequestHandler::handleLpush(const RESPArray &arr) {
    if(arr.size() < 3)
        return {"ERR wrong number of arguments.", '-'};

    long long size;
    const string key = get<string>(arr[1].value);

    for(int i = 2; i < arr.size(); i++) {
        const string value = get<string>(arr[i].value);
        size = store.lpush(key, value);

        if(size == -1)
            return {"WRONGTYPE Operation against a key holding the wrong kind of value", '-'};
    }

    return {size, ':'};
}


RESPValue RequestHandler::handleLrange(const RESPArray &arr) {
    if(arr.size() != 4)
        return {"ERR wrong number of arguments.", '-'};

    RESPArray result;

    const string key = get<string>(arr[1].value);
    const int left = stoi(get<string>(arr[2].value));
    const int right = stoi(get<string>(arr[3].value));

    optional<vector<string>> values = store.lrange(key, left, right);

    if(!values)
        return {"WRONGTYPE Operation against a key holding the wrong kind of value", '-'};

    vector<string> &v = values.value();
    for(auto &e : v)
        result.push_back({e, '$'});

    return {result, '*'};
}