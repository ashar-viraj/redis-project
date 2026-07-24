#pragma once

#include <functional>
#include <string>
using namespace std;

// Installed once by EventLoop so that send_msg() (used e.g. by PUBLISH fan-out)
// always goes through the loop's buffered, non-blocking output path instead of
// calling send() directly. Single-threaded by design: no locking needed.
using SendSink = function<void(int, const string &)>;
void set_send_sink(SendSink sink);
void send_msg(const string &msg, int clientFd);
