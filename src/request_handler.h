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
};