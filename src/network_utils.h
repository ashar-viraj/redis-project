#pragma once

#include <functional>
#include <string>
using namespace std;

using SendInterceptor = function<bool(int, const string &)>;

void set_send_interceptor(SendInterceptor interceptor);
void send_msg(const string &msg, int clientFd);
