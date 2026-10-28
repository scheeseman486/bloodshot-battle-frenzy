#pragma once
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace bloodshot {
// A bounded, nonblocking stdin reader. No worker thread can outlive the server.
// Only the dedicated composition root instantiates this; clients never read stdin.
class BloodshotConsoleInput : public godot::RefCounted {
    GDCLASS(BloodshotConsoleInput, godot::RefCounted)
    bool closed = false;
  protected:
    static void _bind_methods();
  public:
    godot::Dictionary poll();
};
}
