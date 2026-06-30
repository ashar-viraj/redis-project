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
    RESPValue handleBlpop(const RESPArray &arr);

    RESPValue handleType(const RESPArray &arr);
    RESPValue handleXadd(const RESPArray &arr);
    RESPValue handleXrange(const RESPArray &arr);
    RESPValue handleXread(const RESPArray &arr);
    RESPValue handleIncr(const RESPArray &arr);
};