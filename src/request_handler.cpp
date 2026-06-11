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

    if(cmd == "TYPE")
        return handleType(arr);

    if(cmd == "XADD")
        return handleXadd(arr);

    if(cmd == "XRANGE")
        return handleXrange(arr);

    if(cmd == "XREAD")
        return handleXread(arr);

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

            result.push_back({poppedValue.value(), '$'});
        }

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
    string timeoutStr = get<string>(arr[2].value);

    auto res = store.blpop(key, stod(timeoutStr));

    if(!res)
        return {nullptr, '*'};

    RESPArray out;
    out.push_back({res->first, '$'});
    out.push_back({res->second, '$'});

    return {out, '*'};
}

RESPValue RequestHandler::handleType(const RESPArray &arr) {
    if(arr.size() != 2)
        return {"ERR wrong number of arguments.", '-'};

    string key = get<string>(arr[1].value);

    return {store.type(key), '+'};
}

RESPValue RequestHandler::handleXadd(const RESPArray &arr) {
    if(arr.size() < 5 || (arr.size() - 3) % 2 != 0)
        return {"ERR wrong number of arguments.", '-'};

    const string key = get<string>(arr[1].value);
    const string entryId = get<string>(arr[2].value);

    vector<pair<string, string>> fields;
    for(int i = 3; i < arr.size(); i += 2)
        fields.push_back({get<string>(arr[i].value), get<string>(arr[i + 1].value)});

    try {
        string createdId = store.xadd(key, entryId, fields);
        return {createdId, '$'};
    } catch (const exception &e) {
        return {e.what(), '-'};
    } catch(...) {
        return {"ERR unknown error", '-'};
    }
}

RESPValue RequestHandler::handleXrange(const RESPArray &arr) {
    if(arr.size() != 4)
        return {"ERR wrong number of arguments.", '-'};

    optional<StreamType> result = store.xrange(get<string>(arr[1].value),
                                get<string>(arr[2].value),
                                get<string>(arr[3].value));

    if(!result)
        return {
            "WRONGTYPE Operation against a key holding the wrong kind of value",
            '-'
        };

    RESPArray resp;

    for(auto &e : *result) {
        RESPArray respEntry;

        respEntry.push_back({
            streamIDToString(e.id),
            '$'
        });

        RESPArray fields;
        for(const auto &f : e.fields) {
            fields.push_back({f.first, '$'});
            fields.push_back({f.second, '$'});
        }
        respEntry.push_back({fields, '*'});
        resp.push_back({respEntry, '*'});
    }

    return {resp, '*'};
}

RESPValue RequestHandler::handleXread(const RESPArray &arr) {
    if(arr.size() != 4)
        return {"ERR wrong number of arguments.", '-'};

    string keyword = get<string>(arr[1].value);
    for(auto &ch : keyword)
        ch = toupper(ch);

    if(keyword != "STREAMS")
        return {"ERR syntax error", '-'};

    string key = get<string>(arr[2].value);
    string id = get<string>(arr[3].value);

    auto result = store.xread(key, id);

    if(!result.has_value())
        return {nullptr, '*'};

    RESPArray entries;

    for(const auto &entry : *result) {
        RESPArray singleEntry;
        singleEntry.push_back({
            streamIDToString(entry.id),
            '$'
        });

        RESPArray fieldValues;
        for(const auto &field : entry.fields) {
            fieldValues.push_back({field.first, '$'});
            fieldValues.push_back({field.second, '$'});
        }

        singleEntry.push_back({fieldValues, '*'});

        entries.push_back({singleEntry, '*'});
    }

    RESPArray streamResponse;
    if(entries.size()) {
        streamResponse.push_back({key, '$'});
        streamResponse.push_back({entries, '*'});
    }

    RESPArray response;
    if(streamResponse.size())
        response.push_back({streamResponse, '*'});

    if(response.empty())
        return {nullptr, '*'};

    return {response, '*'};
}
