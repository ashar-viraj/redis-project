#include "request_handler.h"
#include "store.h"
#include "network_utils.h"
#include <stdexcept>
#include <iostream>

using namespace std;

void toUpper(string &s) {
    for(auto &e : s)
        e = toupper(e);
}

bool shouldReplicate(const string &cmd) {
    return cmd == "SET" ||
            cmd == "" ||
            cmd == "UNWATCH" ||
            cmd == "WATCH" ||
            cmd == "INCR" ||
            cmd == "XADD" ||
            cmd == "BLPOP" ||
            cmd == "LPOP" ||
            cmd == "RPUSH" ||
            cmd == "LPUSH";
}

bool shouldWriteAOF(const string &cmd) {
    return shouldReplicate(cmd);
}

RequestHandler::RequestHandler(Store &s,
        RESPSerializer &serializer,
        Config &config,
        ReplicationManager &replication,
        AOFManager &aof,
        int fd,
        bool replaying)
        : store(s), serializer(serializer), config(config), replication(replication), aof(aof), clientFd(fd), replaying(replaying) { }

RESPValue RequestHandler::executeCommand(const string &cmd, const RESPArray &arr) {
    RESPValue res;

    if(cmd == "PING") res = handlePing();
    else if(cmd == "ECHO") res = handleEcho(arr);
    else if(cmd == "SET") res = handleSet(arr);
    else if(cmd == "GET") res = handleGet(arr);
    else if(cmd == "RPUSH") res = handleRpush(arr);
    else if(cmd == "LPUSH") res = handleLpush(arr);
    else if(cmd == "LRANGE") res = handleLrange(arr);
    else if(cmd == "LLEN") res = handleLlen(arr);
    else if(cmd == "LPOP") res = handleLpop(arr);
    else if(cmd == "BLPOP") res = handleBlpop(arr);
    else if(cmd == "TYPE") res = handleType(arr);
    else if(cmd == "XADD") res = handleXadd(arr);
    else if(cmd == "XRANGE") res = handleXrange(arr);
    else if(cmd == "XREAD") res = handleXread(arr);
    else if(cmd == "INCR") res = handleIncr(arr);
    else if(cmd == "WATCH") res = handleWatch(arr);
    else if(cmd == "UNWATCH") res = handleUnwatch(arr);
    else if(cmd == "INFO") res = handleInfo(arr);
    else if(cmd == "REPLCONF") res = handleReplConf(arr);
    else if(cmd == "PSYNC") res = handlePsync(arr);
    else if(cmd == "WAIT") res = handleWait(arr);
    else if(cmd == "CONFIG") res = handleConfig(arr);
    else if(cmd == "KEYS") res = handleKeys(arr);
    else if(cmd == "SUBSCRIBE") res = handleSubscribe(arr);
    else if(cmd == "UNSUBSCRIBE") res = handleUnsubscribe(arr);
    else if(cmd == "PUBLISH") res = handlePublish(arr);
    else res = {"ERR unkown command", '-'};

    if(!replaying){
        if(shouldReplicate(cmd))
            replication.propagate(arr);

        if(config.appendOnly && shouldWriteAOF(cmd))
            aof.append(arr);
    }

    return res;
}

RESPValue RequestHandler::handle(const RESPValue &req) {
    if(req.type != '*')
        throw runtime_error("Command must be array");

    RESPArray arr = get<RESPArray>(req.value);

    if(arr.empty())
        throw runtime_error("Empty command");

    string cmd = get<string>(arr[0].value);
    toUpper(cmd);

    if(state.subscribedMode) {
        if(cmd != "SUBSCRIBE" &&
            cmd != "PING" &&
            cmd != "QUIT" &&
            cmd != "UNSUBSCRIBE" &&
            cmd != "PSUBSCRIBE" &&
            cmd != "PUNSUBSCRIBE") {
            return {"ERR Can't execute '" + cmd + "' in subscribed mode", '-'};
        }
    }

    if(cmd == "MULTI") {
        state.inTransaction = true;
        return {"OK", '+'};
    }

    if(cmd == "EXEC") {
        return handleExec();
    }

    if(cmd == "DISCARD") {
        if(!state.inTransaction)
            return {"ERR DISCARD without MULTI", '-'};

        state.queuedCommands.clear();
        state.inTransaction = false;
        state.watchedKeys.clear();
        return {"OK", '+'};
    }

    if(state.inTransaction && cmd != "WATCH") {
        state.queuedCommands.push_back(arr);
        return {"QUEUED", '+'};
    }

    return executeCommand(cmd, arr);
}

RESPValue RequestHandler::handlePing() {
    if(state.subscribedMode) {
        RESPArray res = {
            {"pong", '$'},
            {"", '$'}
        };

        return {res, '*'};
    }

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
        toUpper(option);
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

    store.setValue(key, value, px);
    store.markKeyAsModified(key);

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
    store.markKeyAsModified(key);

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
    store.markKeyAsModified(key);

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

        while(count--) {
            poppedValue = store.lpop(key);

            if(!poppedValue)
                break;

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
    if(arr.size() < 4)
        return {"ERR wrong number of arguments.", '-'};

    bool blocking = false;
    long long timeoutMs = 0;
    int streamsIdx = 1;

    string firstKeyword = get<string>(arr[1].value);
    toUpper(firstKeyword);

    if(firstKeyword == "BLOCK") {
        if(arr.size() < 6)
            return {"ERR wrong number of arguments.", '-'};

        blocking = true;

        try {
            timeoutMs = stoll(get<string>(arr[2].value));
        } catch(...) {
            return {"ERR timeout is not an integer or out of range", '-'};
        }

        if(timeoutMs < 0)
            return {"ERR timeout is negative", '-'};

        streamsIdx = 3;
    }

    string keyword = get<string>(arr[streamsIdx].value);
    toUpper(keyword);

    if(keyword != "STREAMS")
        return {"ERR syntax error", '-'};

    int streamArgs = arr.size() - streamsIdx - 1;
    if(streamArgs < 2 || streamArgs % 2 != 0)
        return {"ERR wrong number of arguments.", '-'};

    int streamCount = streamArgs / 2;
    int keyIdx = streamsIdx + 1;
    int idIdx = keyIdx + streamCount;

    vector<pair<string, string>> requestedStreams;

    for(int i = 0; i < streamCount; i++) {
        string key = get<string>(arr[keyIdx + i].value);
        string id = get<string>(arr[idIdx + i].value);

        requestedStreams.push_back({key, id});
    }

    vector<pair<string, StreamType>> streamResults;

    if(blocking) {
        auto result = store.xreadBlocking(requestedStreams, timeoutMs);
        if(!result)
            return {nullptr, '*'};

        streamResults = *result;
    } else {
        for(const auto &[key, id] : requestedStreams) {
            auto result = store.xread(key, id);

            if(!result || result->empty())
                continue;

            streamResults.push_back({key, *result});
        }
    }

    RESPArray response;

    for(const auto &[key, entriesResult] : streamResults) {
        RESPArray entries;

        for(const auto &entry : entriesResult) {
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

        if(entries.empty())
            continue;

        RESPArray streamResponse;
        streamResponse.push_back({key, '$'});
        streamResponse.push_back({entries, '*'});

        response.push_back({streamResponse, '*'});
    }

    if(response.empty())
        return {nullptr, '*'};

    return {response, '*'};
}

RESPValue RequestHandler::handleIncr(const RESPArray &arr) {
    if(arr.size() != 2)
        return {"ERR wrong number of arguments.", '-'};

    const string key = get<string>(arr[1].value);

    optional<long long> result = store.incr(key);

    if(!result) {
        return {"ERR value is not an integer or out of range", '-'};
    }

    return {*result, ':'};
}

RESPValue RequestHandler::handleExec() {
    if(!state.inTransaction)
        return {"ERR EXEC without MULTI", '-'};

    RESPArray responses;

    auto commands = move(state.queuedCommands);
    state.queuedCommands.clear();
    state.inTransaction = false;

    bool watchedKeysModified = false;

    for(auto &[key, version] : state.watchedKeys) {
        auto currentVersion = store.getKeyVersion(key);
        if(currentVersion != version) {
            watchedKeysModified = true;
            break;
        }
    }
    state.watchedKeys.clear();

    if(watchedKeysModified) {
        return {nullptr, '*'};
    }

    for(auto &command : commands) {
        string cmd = get<string>(command[0].value);
        toUpper(cmd);

        RESPValue response;
        try {
            response = executeCommand(cmd, command);
        }catch (const std::exception& e) {
            response = {e.what(), '-'};
        }
        catch (...) {
            response = {"ERR internal error", '-'};
        }
        responses.push_back(response);
    }

    return {responses, '*'};
}

RESPValue RequestHandler::handleWatch(const RESPArray &arr) {
    if(arr.size() < 2)
        return {"ERR wrong number of arguments.", '-'};

    if(state.inTransaction)
        return {"ERR WATCH inside MULTI is not allowed", '-'};

    for(int i = 1; i < arr.size(); i++) {
        string key = get<string>(arr[i].value);
        state.watchedKeys[key] = store.getKeyVersion(key);
    }

    return {"OK", '+'};
}

RESPValue RequestHandler::handleUnwatch(const RESPArray &arr) {
    if(arr.size() != 1)
        return {"ERR wrong number of arguments.", '-'};

        state.watchedKeys.clear();

    return {"OK", '+'};
}

RESPValue RequestHandler::handleInfo(const RESPArray &arr)
{
    if (arr.size() != 2)
        return {"ERR wrong number of arguments.", '-'};

    string option = get<string>(arr[1].value);
    toUpper(option);

    if (option == "REPLICATION")
    {
        string info = config.isReplica ? "role:slave\n" : "role:master\n";
        info += "master_replid:8371b4fb1155b71f4a04d3e1bc3e18c4a990aeeb\n";
        info += "master_repl_offset:" + to_string(replication.getMasterOffset());
        return {info, '$'};
    }

    return {"OK", '+'};
}

RESPValue RequestHandler::handleReplConf(const RESPArray &arr) {
    if(config.isReplica) {
        if(arr.size() >= 3) {
            string sub = get<string>(arr[1].value);
            toUpper(sub);

            if(sub == "GETACK") {
                RESPArray ack = {
                    {"REPLCONF", '$'},
                    {"ACK", '$'},
                    {to_string(replication.getProcessedOffset()), '$'}
                };

                return {ack, '*'};
            }
        }
    } else {
        if(arr.size() >= 3) {
            string sub = get<string>(arr[1].value);
            toUpper(sub);
            if(sub == "ACK") {
                long long offset = 0;
                try {
                    offset = stoll(get<string>(arr[2].value));
                } catch (...) {}

                replication.updateAcknowledgeOffset(clientFd, offset);
            }
        }
    }

    return {"OK", '+'};
}

RESPValue RequestHandler::handlePsync(const RESPArray &arr) {
    string reply = "FULLRESYNC " + config.masterReplId + " " + to_string(replication.getMasterOffset());
    replication.addReplica(clientFd);

    return {reply, '+'};
}

RESPValue RequestHandler::handleWait(const RESPArray &arr) {
    if(arr.size() != 3)
        return {"ERR wrong number of arguments.", '-'};

    long long numReplicas, timeoutMs;
    try {
        numReplicas = stoll(get<string>(arr[1].value));
        timeoutMs = stoll(get<string>(arr[2].value));
    } catch (...) {
        return {"ERR value is not an integer or out of range", '-'};
    }

    int acked = replication.waitForAcks((int)numReplicas, timeoutMs);

    return {(long long)acked, ':'};
}

RESPValue RequestHandler::handleConfig(const RESPArray &arr) {
    if(arr.size() != 3)
        return {"ERR wrong number of arguments.", '-'};

    string sub = get<string>(arr[1].value);
    toUpper(sub);

    if(sub == "GET") {
        RESPArray res;
        string param = get<string>(arr[2].value);
        if(param == "dir") {
            res = {
                {"dir", '$'},
                {config.dir , '$'}
            };
        } else if(param == "dbfilename") {
            res = {
                {"dbfilename", '$'},
                {config.dbFileName, '$'}
            };
        } else if(param == "appendonly") {
            res = {
                {"appendonly", '$'},
                {config.appendOnly ? "yes" : "no", '$'}
            };
        } else if(param == "appenddirname") {
            res = {
                {"appenddirname", '$'},
                {config.appendDirName, '$'}
            };
        } else if(param == "appendfilename") {
            res = {
                {"appendfilename", '$'},
                {config.appendFileName, '$'}
            };
        } else if(param == "appendfsync") {
            res = {
                {"appendfsync", '$'},
                {config.appendFsync, '$'}
            };
        }

        return {res, '*'};
    }

    return {"ERR unsupported CONFIG subcommand", '+'};
}

RESPValue RequestHandler::handleKeys(const RESPArray &arr) {
    if(arr.size() != 2)
        return {"ERR wrong number of arguments.", '-'};

    string pattern = get<string>(arr[1].value);

    if(pattern != "*")
        return {"ERR only * is supported", '-'};

    vector<string> keys = store.getkeys();
    RESPArray res;
    for(auto &key : keys)
        res.push_back({key, '$'});
    return {res, '*'};
}

RESPValue RequestHandler::handleSubscribe(const RESPArray &arr) {
    if(arr.size() != 2)
        return {"ERR wrong number of arguments.", '-'};

    string channel = get<string>(arr[1].value);
    int count = store.subscribe(clientFd, channel);
    state.subscribedMode = true;

    RESPArray res = {
        {"subscribe", '$'},
        {channel, '$'},
        {count, ':'}
    };

    return {res, '*'};
}

RESPValue RequestHandler::handleUnsubscribe(const RESPArray &arr) {
    if(arr.size() != 2)
        return {"ERR wrong number of arguments.", '-'};

    const string channel = get<string>(arr[1].value);

    long long count = store.unsubscribe(clientFd, channel);

    if(count == 0)
        state.subscribedMode = false;

    RESPArray res = {
        {"unsubscribe", '$'},
        {channel, '$'},
        {count, ':'}
    };

    return {res, '*'};
}

RESPValue RequestHandler::handlePublish(const RESPArray &arr) {
    if(arr.size() != 3)
        return {"ERR wrong number of arguments.", '-'};

    const string channel = get<string>(arr[1].value);
    const string message = get<string>(arr[2].value);

    vector<int> subscribers = store.getSubscribers(channel);
    RESPArray res = {
        {"message", '$'},
        {channel, '$'},
        {message, '$'}
    };

    RESPSerializer serializer;
    const string msg = serializer.serialize({res, '*'});

    for(auto &sub : subscribers)
        send_msg(msg, sub);

    return {(long long)subscribers.size(), ':'};
}
