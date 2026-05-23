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

    return {"ERR unkown command", '-'};
}

RESPValue RequestHandler::handlePing(){
    return {"PONG", '+'};
}

RESPValue RequestHandler::handleEcho(const RESPArray &arr) {
    if(arr.size() != 2)
        return {"ERR wrong number of arguements", '-'};

    // cout << "handleEcho for : " << get<string>(arr[1].value) << endl;
    return {get<string>(arr[1].value), '$'};
}

RESPValue RequestHandler::handleSet(const RESPArray &arr) {
    if(arr.size() != 3) 
        return {"ERR wrong number of arguments.", '-'};

    string key = get<string>(arr[1].value);
    string value = get<string>(arr[2].value);

    store.set(key, value);

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
