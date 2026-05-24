#pragma once
#include "RESP/resp_parser.h"
#include "store.h"

class RequestHandler{
private:
    Store &store;

public:
    RequestHandler(Store &store);
    RESPValue handle(const RESPValue &req);

private:
    RESPValue handlePing();
    RESPValue handleEcho(const RESPArray &arr);
    RESPValue handleSet(const RESPArray &arr);
    RESPValue handleGet(const RESPArray &arr);
    RESPValue handleRpush(const RESPArray &arr);
    RESPValue handleLpush(const RESPArray &arr);
    RESPValue handleLrange(const RESPArray &arr);
    RESPValue handleLlen(const RESPArray &arr);
    RESPValue handleLpop(const RESPArray &arr);
};