#pragma once
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

namespace bloodshot {
// Harden the application's existing credential directory/files. No network path
// reaches this API. Fail closed if ownership or permission updates cannot be made.
class BloodshotPrivateFiles : public godot::RefCounted {
    GDCLASS(BloodshotPrivateFiles, godot::RefCounted)
  protected:
    static void _bind_methods();
  public:
    int protect(const godot::String &path, bool directory);
};
}
