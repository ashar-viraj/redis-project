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

    if(cmd == "LLEN")
        return handleLlen(arr);

    if(cmd == "LPOP")
        return handleLpop(arr);

    if(cmd == "BLPOP")
        return handleBlpop(arr);

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
        try {
            if(option == "PX")
                px = stoll(get<string>(arr[4].value));  
            else if(option == "EX")
                px = stoll(get<string>(arr[4].value)) * 1000;
            else
                return {"ERR Unsupported option.", '-'};
        } catch (...) {
            return {"expiry value is not an integer or out of range", '-'};
        }
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

RESPValue RequestHandler::handleLlen(const RESPArray &arr) {
    if(arr.size() != 2)
        return {"ERR wrong number of arguments.", '-'};
    
    const string key = get<string>(arr[1].value);
    
    long long size = store.llen(key);
    
    if(size == -1)
        return {"WRONGTYPE Operation against a key holding the wrong kind of value", '-'};
        
    return {size, ':'};
}

RESPValue RequestHandler::handleLpop(const RESPArray &arr) {
    if(arr.size() != 2 && arr.size() != 3)
        return {"ERR wrong number of arguments.", '-'};

    const string key = get<string>(arr[1].value);

    int count = 1;
    optional<string> poppedValue;

    if(arr.size() == 3) {
        try {
            count = stoi(get<string>(arr[2].value));
            if(count < 0)
                return {"count is out of range, must be positive", '-'};
        } catch(...) {
            return {"count is not integer or out of range", '-'};
        }

        RESPArray result;

        cout << "Count :" << count << endl;
        while(count--) {
            poppedValue = store.lpop(key);

            if(!poppedValue) {
                cout << "Not found\n";
                break;
            }
            
            cout << "Popped Value: " << poppedValue.value() << endl;
            result.push_back({poppedValue.value(), '$'});
        }

        cout << "Result size: " << result.size() << endl;

        return {result, '*'};

    }
    else {
        poppedValue = store.lpop(key);

        if(!poppedValue)
            return {nullptr, '$'};

        return {poppedValue.value(), '$'};
    }
}

RESPValue RequestHandler::handleBlpop(const RESPArray &arr) {
    if(arr.size() != 3)
        return {"ERR wrong number of arguments.", '-'};

    string key = get<string>(arr[1].value);

    auto res = store.blpop(key);

    if(!res)
        return {nullptr, '*'};

    RESPArray out;
    out.push_back({res->first, '$'});
    out.push_back({res->second, '$'});

    return {out, '*'};
}