#pragma once
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace bloodshot {
// Portable primitive grammar only. Envelope/SHA and gameplay schema validation
// remain in GDScript. This class never accepts object or engine Variant
// decoding.
class BloodshotPrimitiveCodec : public godot::RefCounted {
    GDCLASS(BloodshotPrimitiveCodec, godot::RefCounted)
  protected:
    static void _bind_methods();

  public:
    godot::Array project_scalar_records(const godot::Array &values,
                                        const godot::Dictionary &allowed) const;
    godot::PackedInt32Array select_integer_records(const godot::Array &values,
                                                   const godot::String &field,
                                                   int64_t low, int64_t high,
                                                   int64_t first) const;
    godot::Dictionary apply_frozen(const godot::Variant &before,
                                   const godot::Dictionary &patch) const;
    void freeze_tree(const godot::Variant &value) const;
    godot::Dictionary difference(const godot::Variant &before,
                                 const godot::Variant &after) const;
    godot::Dictionary encode_payload(const godot::Dictionary &value,
                                     bool visual) const;
    bool validate_scalar_records(const godot::Array &values,
                                 const godot::Dictionary &rules,
                                 const godot::Array &required) const;
    godot::Dictionary compress_payload(const godot::PackedByteArray &bytes,
                                       int level) const;
    godot::Dictionary decompress_payload(const godot::PackedByteArray &bytes,
                                         int expected) const;
    godot::Dictionary decode_payload(const godot::PackedByteArray &bytes,
                                     bool visual) const;
};
} // namespace bloodshot
