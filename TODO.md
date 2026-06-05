# disconnected waiters should behave exactly like timed-out waiters
struct WaitingClient
{
    mutex mtx;
    condition_variable cv;

    optional<string> poppedValue;

    bool completed = false;

    bool disconnected = false;
};

When socket thread detects:

recv(...) <= 0

it would mark:

waiter->disconnected = true;
waiter->completed = true;
waiter->cv.notify_one();


# RESP Parser TODOs

These are postponed improvements for making the RESP parser production-safe.

---

## 1. Null Bulk String Support

RESP supports null bulk strings.

Example:

```resp
$-1\r\n
```

Meaning:

```
null
```

Current parser assumes every bulk string has data.

Future fix:

```cpp
int strLen = stoi(readLine(buffer, idx));

if(strLen == -1)
{
    // represent null
}
```

Possible representations:

- `optional<string>`
- dedicated Null RESP type
- sentinel value

---

## 2. Null Array Support

RESP supports null arrays.

Example:

```resp
*-1\r\n
```

Meaning:

```
null array
```

Current parser assumes arrays always contain elements.

Future fix:

```cpp
int size = stoi(readLine(buffer, idx));

if(size == -1)
{
    // handle null array
}
```

---

## 3. Bulk String Bounds Checking

Current implementation:

```cpp
string str = buffer.substr(idx, strLen);
```

Problem:

If client sends malformed input:

```resp
$100\r\nabc\r\n
```

Parser may read beyond available data.

Future fix:

```cpp
if(idx + strLen > buffer.size())
{
    throw runtime_error(
        "Incomplete bulk string"
    );
}
```

---

## 4. Validate CRLF Carefully

Current validation should verify both bytes.

Correct:

```cpp
if(
    buffer[idx] != '\r'
    || buffer[idx+1] != '\n'
)
{
    throw runtime_error(
        "Malformed RESP"
    );
}
```

RESP heavily depends on CRLF correctness.

---

## 5. Future Socket Improvement

Current:

```cpp
recv(...)
buffer[msg_len] = '\0'
```

Works for current stages.

Future production-safe design:

```cpp
string input(buffer, msg_len);
parser.parse(input);
```

Reason:

- handles binary data
- avoids null-termination assumptions
- supports embedded '\0'

Important for later RESP binary-safe handling.

---

## 6. Partial TCP Reads

Current assumption:

```
one recv() = one full RESP message
```

TCP does NOT guarantee this.

Example:

recv #1:

```resp
*2\r\n$4\r\nEC
```

recv #2:

```resp
HO\r\n$3\r\nhey\r\n
```

Future solution:

- maintain per-client input buffer
- append recv() data
- parse only when full message available

Required for real Redis behavior.

---

