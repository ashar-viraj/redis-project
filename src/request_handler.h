#pragma once
#include "resp_parser.h"

class RequestHandler{
public:
    RESPValue handle(const RESPValue &req);

private:
    RESPValue handlePing();
    RESPValue handleEcho(const RESPArray &arr);
};