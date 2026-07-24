#include "request_handler.h"
#include "store.h"
#include "./GEO/geo_utils.h"
#include "./SHA/sha256.h"
#include "network_utils.h"
#include <stdexcept>
#include <iostream>

using namespace std;

void toUpper(string &s) {
    for(auto &e : s)
        e = toupper(e);
}

bool shouldReplicate(const string &cmd) {
    // BLPOP replicates explicitly (see finalizeBlpop) only when it actually
    // pops a value, whether that happens immediately or after being parked
    // by EventLoop -- it is deliberately excluded here to avoid propagating
    // it a second time (or propagating it when it resolved to nil).
    return cmd == "SET" ||
            cmd == "" ||
            cmd == "UNWATCH" ||
            cmd == "WATCH" ||
            cmd == "INCR" ||
            cmd == "XADD" ||
            cmd == "LPOP" ||
            cmd == "RPUSH" ||
            cmd == "LPUSH" ||
            cmd == "ZADD" ||
            cmd == "GEOADD";
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
        : store(s),
        serializer(serializer),
        config(config),
        replication(replication),
        aof(aof), clientFd(fd),
        replaying(replaying) {
            state.authenticated = config.defaultUser.nopass;
}

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
    else if(cmd == "ZADD") res = handleZadd(arr);
    else if(cmd == "ZRANK") res = handleZrank(arr);
    else if(cmd == "ZRANGE") res = handleZrange(arr);
    else if(cmd == "ZCARD") res = handleZcard(arr);
    else if(cmd == "ZSCORE") res = handleZscore(arr);
    else if(cmd == "ZREM") res = handleZrem(arr);
    else if(cmd == "GEOADD") res = handleGeoadd(arr);
    else if(cmd == "GEOPOS") res = handleGeopos(arr);
    else if(cmd == "GEODIST") res = handleGeodist(arr);
    else if(cmd == "GEOSEARCH") res = handleGeosearch(arr);
    else if(cmd == "ACL") res = handleAcl(arr);
    else if(cmd == "AUTH") res = handleAuth(arr);
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

    if(!state.authenticated && cmd != "AUTH")
        return {"NOAUTH Authentication required.", '-'};

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
    // Reached only from a non-parking context (e.g. inside MULTI/EXEC).
    // Real Redis never blocks inside a transaction either -- attempt once
    // and reply nil if nothing is available yet.
    string key;
    double timeoutSeconds;

    auto res = tryBlpop(arr, key, timeoutSeconds);
    return res.value_or(RESPValue{nullptr, '*'});
}

optional<RESPValue> RequestHandler::tryBlpop(const RESPArray &arr, string &outKey, double &outTimeoutSeconds) {
    if(arr.size() != 3)
        return RESPValue{"ERR wrong number of arguments.", '-'};

    outKey = get<string>(arr[1].value);

    try {
        outTimeoutSeconds = stod(get<string>(arr[2].value));
    } catch(const exception &e) {
        return RESPValue{e.what(), '-'};
    }

    optional<string> val = store.tryLpop(outKey);
    if(!val)
        return nullopt;

    return finalizeBlpop(outKey, *val, arr);
}

RESPValue RequestHandler::finalizeBlpop(const string &key, const string &value, const RESPArray &originalArr) {
    RESPArray out;
    out.push_back({key, '$'});
    out.push_back({value, '$'});

    if(!replaying) {
        replication.propagate(originalArr);

        if(config.appendOnly)
            aof.append(originalArr);
    }

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
        // Reached only from a non-parking context (e.g. inside MULTI/EXEC) --
        // attempt once and reply nil if nothing is available yet, same as
        // BLPOP's non-parking fallback.
        auto resolved = store.resolveStreamIds(requestedStreams);
        auto result = store.tryXread(resolved);
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

    return formatXreadResponse(streamResults);
}

RESPValue RequestHandler::formatXreadResponse(const vector<pair<string, StreamType>> &streamResults) {
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

optional<RESPValue> RequestHandler::tryXreadBlock(const RESPArray &arr, vector<pair<string, string>> &outResolvedStreams, long long &outTimeoutMs) {
    if(arr.size() < 6)
        return RESPValue{"ERR wrong number of arguments.", '-'};

    try {
        outTimeoutMs = stoll(get<string>(arr[2].value));
    } catch(...) {
        return RESPValue{"ERR timeout is not an integer or out of range", '-'};
    }

    if(outTimeoutMs < 0)
        return RESPValue{"ERR timeout is negative", '-'};

    string keyword = get<string>(arr[3].value);
    toUpper(keyword);

    if(keyword != "STREAMS")
        return RESPValue{"ERR syntax error", '-'};

    int streamArgs = (int)arr.size() - 4;
    if(streamArgs < 2 || streamArgs % 2 != 0)
        return RESPValue{"ERR wrong number of arguments.", '-'};

    int streamCount = streamArgs / 2;
    int keyIdx = 4;
    int idIdx = keyIdx + streamCount;

    vector<pair<string, string>> requestedStreams;
    for(int i = 0; i < streamCount; i++) {
        string key = get<string>(arr[keyIdx + i].value);
        string id = get<string>(arr[idIdx + i].value);
        requestedStreams.push_back({key, id});
    }

    outResolvedStreams = store.resolveStreamIds(requestedStreams);

    auto result = store.tryXread(outResolvedStreams);
    if(!result)
        return nullopt;

    return formatXreadResponse(*result);
}

optional<RESPValue> RequestHandler::resolveXread(const vector<pair<string, string>> &resolvedStreams) {
    auto result = store.tryXread(resolvedStreams);
    if(!result)
        return nullopt;

    return formatXreadResponse(*result);
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
    // Reached only from a non-parking context (e.g. inside MULTI/EXEC) --
    // real Redis doesn't actually wait for replicas inside a transaction
    // either, it just reports the current ack count.
    int numReplicas;
    long long targetOffset, timeoutMs;

    auto res = tryWait(arr, numReplicas, targetOffset, timeoutMs);
    if(res)
        return *res;

    return {(long long)replication.countAcked(targetOffset), ':'};
}

optional<RESPValue> RequestHandler::tryWait(const RESPArray &arr, int &outNumReplicas, long long &outTargetOffset, long long &outTimeoutMs) {
    if(arr.size() != 3)
        return RESPValue{"ERR wrong number of arguments.", '-'};

    long long numReplicas;
    try {
        numReplicas = stoll(get<string>(arr[1].value));
        outTimeoutMs = stoll(get<string>(arr[2].value));
    } catch (...) {
        return RESPValue{"ERR value is not an integer or out of range", '-'};
    }
    outNumReplicas = (int)numReplicas;

    if(!replication.hasPendingWrites()) {
        outTargetOffset = replication.getMasterOffset();
        return RESPValue{replication.getReplicaCount(), ':'};
    }

    outTargetOffset = replication.requestAcks();

    if(outTargetOffset == 0)
        return RESPValue{replication.getReplicaCount(), ':'};

    int acked = replication.countAcked(outTargetOffset);
    if(acked >= outNumReplicas)
        return RESPValue{(long long)acked, ':'};

    return nullopt;
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

RESPValue RequestHandler::handleZadd(const RESPArray &arr) {
    if(arr.size() != 4)
        return {"ERR wrong number of arguments", '-'};

    const string key = get<string>(arr[1].value);
    double score;

    try {
        score = stod(get<string>(arr[2].value));
    } catch (...) {
        return {"ERR value is not a valid float", '-'};
    }

    const string member = get<string>(arr[3].value);
    long long inserted = store.zadd(key, score, member);

    if(inserted == -1)
        return {"WRONGTYPE Operation against a key holding the wrong kind of value", '-'};

    store.markKeyAsModified(key);

    return {inserted, ':'};
}

RESPValue RequestHandler::handleZrank(const RESPArray &arr) {
    if(arr.size() != 3)
        return {"ERR wrong number of arguments", '-'};

    const string key = get<string>(arr[1].value);
    const string member = get<string>(arr[2].value);

    auto rank = store.zrank(key, member);

    if(!rank)
        return {nullptr, '$'};


    return {*rank, ':'};
}

RESPValue RequestHandler::handleZrange(const RESPArray &arr) {
    if(arr.size() != 4)
        return {"ERR wrong number of arguments", '-'};

    const string key = get<string>(arr[1].value);
    const int start = stoi(get<string>(arr[2].value));
    const int end = stoi(get<string>(arr[3].value));

    auto members = store.zrange(key, start, end);

    RESPArray res;
    if(!members)
        return {res, '*'};

    for(auto &mem : *members)
        res.push_back({mem, '$'});

    return {res, '*'};
}

RESPValue RequestHandler::handleZcard(const RESPArray &arr) {
    if(arr.size() != 2)
        return {"ERR wrong number of arguments", '-'};

    const string key = get<string>(arr[1].value);

    long long card = store.zcard(key);

    return {card, ':'};
}

RESPValue RequestHandler::handleZscore(const RESPArray &arr) {
    if(arr.size() != 3)
        return {"ERR wrong number of arguments", '-'};

    const string key = get<string>(arr[1].value);
    const string member = get<string>(arr[2].value);

    auto score = store.zscore(key, member);

    if(!score)
        return {nullptr, '$'};

    return {*score, '$'};
}

RESPValue RequestHandler::handleZrem(const RESPArray &arr) {
    if(arr.size() != 3)
        return {"ERR wrong number of arguments", '-'};

    const string key = get<string>(arr[1].value);
    const string member = get<string>(arr[2].value);

    long long res = store.zrem(key, member);

    return {res, ':'};
}

RESPValue RequestHandler::handleGeoadd(const RESPArray &arr) {
    if(arr.size() != 5)
        return {"ERR wrong number of arguments", '-'};

    double latitude, longitude;

    try {
        longitude = stod(get<string>(arr[2].value));
        latitude = stod(get<string>(arr[3].value));
    } catch (...) {
        return {"ERR invalid longitude/latitude", '-'};
    }

    bool invalidLatitude = latitude < -85.05112878 || latitude > 85.05112878;
    bool invalidLongitude = longitude < -180.0 || longitude > 180.0;

    if(invalidLongitude && invalidLatitude)
        return {"ERR invalid longitude latitude", '-'};

    if(invalidLongitude)
        return {"ERR invalid longitude", '-'};

    if(invalidLatitude)
        return {"ERR invalid latitude", '-'};

    const string key = get<string>(arr[1].value);
    const string member = get<string>(arr[4].value);
    uint64_t score = calculateGeoScore(longitude, latitude);

    long long inserted = store.zadd(key, static_cast<double>(score), member);

    if(inserted == -1)
        return {"WRONGTYPE Operation against a key holding the wrong kind of value", '-'};

    store.markKeyAsModified(key);

    return {inserted, ':'};
}

RESPValue RequestHandler::handleGeopos(const RESPArray &arr) {
    if(arr.size() < 3)
        return {"ERR wrong number of arguments", '-'};

    string key = get<string>(arr[1].value);
    RESPArray res;

    for(int i = 2; i < arr.size(); i++) {
        const string member = get<string>(arr[i].value);
        auto score = store.zscore(key, member);

        if(score){
            auto [longitude, latitude] = decodeGeoScore(stoull(*score));
            RESPArray pos = {
                {to_string(longitude), '$'},
                {to_string(latitude), '$'}
            };

            res.push_back({pos, '*'});
        } else {
            res.push_back({nullptr, '*'});
        }
    }

    return {res, '*'};
}

RESPValue RequestHandler::handleGeodist(const RESPArray &arr) {
    if(arr.size() != 4)
        return {"ERR wrong number of arguments", '-'};

    string key = get<string>(arr[1].value);
    string member1 = get<string>(arr[2].value);
    string member2 = get<string>(arr[3].value);

    auto score1 = store.zscore(key, member1);
    auto score2 = store.zscore(key, member2);

    if(!score1 || !score2)
        return {nullptr, '$'};

    auto [lon1, lat1] = decodeGeoScore(stoull(*score1));
    auto [lon2, lat2] = decodeGeoScore(stoull(*score2));

    double distance = getGeoDistance(lon1, lat1, lon2, lat2);

    ostringstream oss;

    oss << fixed << setprecision(4) << distance;

    return {oss.str(), '$'};
}

RESPValue RequestHandler::handleGeosearch(const RESPArray &arr) {
    if(arr.size() != 8)
        return {"ERR wrong number of arguments", '-'};

    string key, unit;
    double centerLon, centerLat;
    long long radius;
    key = get<string>(arr[1].value);
    unit = get<string>(arr[7].value);

    try {
        centerLon = stod(get<string>(arr[3].value));
        centerLat = stod(get<string>(arr[4].value));
        radius = stoll(get<string>(arr[6].value));
    } catch (...) {
        return {"ERR invalid longitude, latitude or radius", '-'};
    }

    if(unit == "km")
        radius *= 1000;
    else if(unit == "mi")
        radius *= 1609.34;
    else if(unit == "ft")
        radius *= 0.3048;
    else if(unit != "m")
        return {"ERR invalid unit", '-'};

    auto members = store.getSortedSet(key);

    RESPArray resp;

    for(auto &entry : *members)
    {
        auto [lon, lat] = decodeGeoScore((uint64_t)entry.score);
        double dist = getGeoDistance(centerLon, centerLat, lon, lat);
        if(dist <= radius)
            resp.push_back({entry.member, '$'});
    }

    return {resp, '*'};
}

RESPValue RequestHandler::handleAcl(const RESPArray &arr) {
    if(arr.size() < 2)
        return {"ERR wrong number of arguments", '-'};

    string sub = get<string>(arr[1].value);
    toUpper(sub);

    if(sub == "WHOAMI" && arr.size() == 2)
        return {"default", '$'};
    if(sub == "GETUSER" && arr.size() == 3) {
        string username = get<string>(arr[2].value);
        if(username != "default")
            return {"ERR no such user", '-'};

        RESPArray flags, passwords;

        if(config.defaultUser.nopass)
            flags.push_back({"nopass", '$'});

        for(const auto &hash : config.defaultUser.passwordHashes)
            passwords.push_back({hash, '$'});

        RESPArray result = {
            {"flags", '$'},
            {flags, '*'},
            {"passwords", '$'},
            {passwords, '*'}
        };

        return {result, '*'};
    }

    if(sub == "SETUSER" && arr.size() == 4) {
        const string username = get<string>(arr[2].value);

        if(username != "default")
            return {"ERR no such user", '-'};

        string rule = get<string>(arr[3].value);

        if(rule.empty() || rule[0] != '>')
            return {"ERR unsupported ACL rule", '-'};

        const string password = rule.substr(1);

        const string hash = sha256(password);
        config.defaultUser.nopass = false;

        // config.defaultUser.passwordHashes.clear();
        config.defaultUser.passwordHashes.push_back(hash);

        return {"OK", '+'};
    }

    return {"ERR unknown ACL subcommand", '-'};
}

RESPValue RequestHandler::handleAuth(const RESPArray &arr) {
    if(arr.size() != 3)
        return {"ERR wrong number of arguments", '-'};

    string username = get<string>(arr[1].value);
    string password = get<string>(arr[2].value);

    if(username != "default")
        return {"WRONGPASS invalid username-password pair or user is disabled.", '-'};

    const string hash = sha256(password);
    for(auto &storedHash : config.defaultUser.passwordHashes) {
        if(storedHash == hash) {
            state.authenticated = true;
            return {"OK", '+'};
        }
    }

    return {"WRONGPASS invalid username-password pair or user is disabled.", '-'};
}
