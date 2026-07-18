#include "aof_manager.h"
#include "../request_handler.h"

#include <filesystem>

#include <iostream>
using namespace std;

AOFManager::AOFManager(Config &config, RESPSerializer &serializer) : config(config), serializer(serializer) {}

string AOFManager::getActiveAofFileName() {
    filesystem::path manifestPath = filesystem::path(config.dir) /
                                    config.appendDirName /
                                    (config.appendFileName + ".manifest");

    ifstream in(manifestPath);

    if (!in.is_open())
        throw runtime_error("Failed to open manifest");

    string line;
    getline(in, line);

    stringstream ss(line);
    string word, fileName, seq, seqNo, type, typeVal;

    ss >> word;
    ss >> fileName;
    ss >> seq;
    ss >> seqNo;
    ss >> type;
    ss >> typeVal;

    if(word != "file" || seq != "seq" || type != "type")
        throw runtime_error("Invalid manifest");

    return fileName;
}

void AOFManager::initialize() {
    filesystem::path manifestPath = filesystem::path(config.dir) /
                                    config.appendDirName /
                                    (config.appendFileName + ".manifest");
    filesystem::path aofDir = filesystem::path(config.dir) / config.appendDirName;
    if(!filesystem::exists(manifestPath)){
        filesystem::create_directories(aofDir);

        filesystem::path aofFile = aofDir / (config.appendFileName + ".1.incr.aof");
        aofStream.open(aofFile);
        aofStream.close();

        ofstream manifest(manifestPath);
        manifest << "file "
                 << config.appendFileName
                 << ".1.incr.aof "
                 << "seq 1 "
                 << "type i\n";
        manifest.close();
    }

    string activeFile = getActiveAofFileName();
    filesystem::path activeFilePath = aofDir / activeFile;
    aofStream.open(activeFilePath, ios::app);

    if(!aofStream.is_open())
        throw runtime_error("Failed to open active AOF file");
}

void AOFManager::append(const RESPArray &cmd) {
    string bytes = serializer.serialize({cmd, '*'});

    aofStream << bytes;

    if(config.appendFsync == "always")
        aofStream.flush();
}

void AOFManager::replay(Store &store, ReplicationManager &replication) {
    RESPParser parser;
    RequestHandler handler(store, serializer, config, replication, *this, -1, true);

    filesystem::path path = filesystem::path(config.dir) /
                            config.appendDirName /
                            getActiveAofFileName();

    ifstream in(path);

    if(!in)
        return;
    string bytes{
        istreambuf_iterator<char>{in},
        istreambuf_iterator<char>{}
    };

    if(bytes.empty())
        return;

    size_t offset = 0;

    while(offset < bytes.size()) {
        try {
            size_t consumed = 0;
            RESPValue req = parser.parse(bytes, consumed, offset);

            handler.handle(req);
            offset += consumed;
        } catch (...) {
            break;
        }
    }
}
