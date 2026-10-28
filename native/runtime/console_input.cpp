#include "console_input.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <cerrno>
#include <poll.h>
#include <unistd.h>
#endif

using namespace godot;
namespace bloodshot {
void BloodshotConsoleInput::_bind_methods() {
    ClassDB::bind_method(D_METHOD("poll"), &BloodshotConsoleInput::poll);
}

Dictionary BloodshotConsoleInput::poll() {
    Dictionary result;
    PackedByteArray bytes;
    String error;
    if (!closed) {
        uint8_t buffer[4096];
        int count = 0;
#ifdef _WIN32
        HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
        DWORD mode = 0;
        if (input == nullptr || input == INVALID_HANDLE_VALUE) {
            closed = true;
        } else if (GetConsoleMode(input, &mode)) {
            // ReadConsole/stdio can wait for Enter even after input is signalled.
            // Reading available key records instead never waits for a whole line.
            DWORD available = 0;
            if (!GetNumberOfConsoleInputEvents(input, &available)) {
                closed = true;
                error = "Cannot inspect console input";
            } else if (available) {
                INPUT_RECORD records[128];
                DWORD read = 0;
                DWORD amount = available < 128 ? available : 128;
                if (!ReadConsoleInputW(input, records, amount, &read)) {
                    closed = true;
                    error = "Cannot read console input";
                } else {
                    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
                    for (DWORD i = 0; i < read; ++i) {
                        const auto &key = records[i].Event.KeyEvent;
                        if (records[i].EventType != KEY_EVENT || !key.bKeyDown) continue;
                        WCHAR ch = key.uChar.UnicodeChar;
                        if (ch == L'\r') ch = L'\n';
                        // Command grammar and source-font names are ASCII.
                        if (ch != L'\n' && ch != L'\b' && (ch < 32 || ch > 126)) continue;
                        for (unsigned repeat = 0; repeat < key.wRepeatCount && count < 4096; ++repeat) {
                            buffer[count++] = static_cast<uint8_t>(ch);
                            const WCHAR *echo = ch == L'\b' ? L"\b \b" : (ch == L'\n' ? L"\r\n" : &ch);
                            DWORD written = 0;
                            WriteConsoleW(output, echo, ch == L'\b' ? 3 : (ch == L'\n' ? 2 : 1), &written, nullptr);
                        }
                    }
                }
            }
        } else {
            DWORD available = sizeof(buffer);
            const DWORD type = GetFileType(input);
            if (type == FILE_TYPE_PIPE && !PeekNamedPipe(input, nullptr, 0, nullptr, &available, nullptr)) {
                DWORD reason = GetLastError();
                if (reason != ERROR_BROKEN_PIPE && reason != ERROR_PIPE_NOT_CONNECTED && reason != ERROR_NO_DATA)
                    error = "Cannot poll redirected stdin; use a Windows console or native pipe";
                closed = true; // Closed pipe / detached service input.
            } else if (type != FILE_TYPE_PIPE && type != FILE_TYPE_DISK) {
                closed = true;
            } else if (available) {
                DWORD read = 0;
                const DWORD amount = available < sizeof(buffer) ? available : sizeof(buffer);
                if (!ReadFile(input, buffer, amount, &read, nullptr) || !read) closed = true;
                else count = static_cast<int>(read);
            }
        }
#else
        pollfd input{STDIN_FILENO, POLLIN, 0};
        int ready = ::poll(&input, 1, 0);
        if (ready < 0 && errno != EINTR) {
            closed = true;
            error = "Cannot inspect console input";
        } else if (ready > 0 && (input.revents & (POLLIN | POLLHUP))) {
            // One reader, canonical TTY or pipe/file: read only available bytes.
            ssize_t read = ::read(STDIN_FILENO, buffer, sizeof(buffer));
            if (read == 0) closed = true;
            else if (read > 0) count = static_cast<int>(read);
            else if (errno != EINTR && errno != EAGAIN) {
                closed = true;
                error = "Cannot read console input";
            }
        } else if (ready > 0 && (input.revents & (POLLERR | POLLNVAL))) closed = true;
#endif
        if (count) {
            bytes.resize(count);
            for (int i = 0; i < count; ++i) bytes.set(i, buffer[i]);
        }
    }
    result["bytes"] = bytes;
    result["eof"] = closed;
    result["error"] = error;
    return result;
}
}
