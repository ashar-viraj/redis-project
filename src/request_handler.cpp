#include "request_handler.h"
#include <stdexcept>
#include <iostream>

using namespace std;

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