#include "primitive_codec.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <limits>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>
#include <zstd.h>

using namespace godot;
namespace {
// These are the existing checkpoint grammar limits, not separate network
// limits.
constexpr size_t MAX_BYTES = 2 * 1024 * 1024;
constexpr size_t MAX_VALUES = 100000;
constexpr size_t MAX_COLLECTION = 8192;
constexpr unsigned MAX_DEPTH = 24;
struct KeyLayout {
    Array original;
    std::vector<Variant> keys;
    std::vector<std::vector<uint8_t>> prefixes;
};
struct Grammar {
    // Every shared input Array/Dictionary below is const. Godot's non-const
    // indexing of a read-only container writes a shared temporary Variant;
    // treating that accessor as a read races other encoders and the main thread.
    // A bounded, per-encode cache of dictionary *key layouts*, never values.
    // Actor records share keys; sorting/ASCII encoding them 180 times is waste.
    std::unordered_map<uint32_t, std::vector<std::shared_ptr<KeyLayout>>>
        layouts;
    size_t layout_count = 0, layout_bytes = 0;
    // Views point only into this call's immutable input buffer. Repeated actor
    // keys share Godot String storage; no input pointer survives decode.
    std::unordered_map<std::string_view, String> strings;
    size_t string_bytes = 0, strings_created = 0;
    bool visual;
    std::string error;
    size_t values = 0;
    std::vector<uint8_t> output;
    const uint8_t *input = nullptr;
    size_t length = 0, offset = 0;
    explicit Grammar(bool allow_visual) : visual(allow_visual) {}
    void fail(const char *message) {
        if (error.empty())
            error = message;
    }
    void integer(uint64_t value, unsigned size) {
        for (unsigned i = 0; i < size; ++i)
            output.push_back(uint8_t(value >> (i * 8)));
    }
    void real(double value) {
        uint64_t bits;
        std::memcpy(&bits, &value, sizeof(bits));
        integer(bits, 8);
    }
    bool count(unsigned depth) {
        if (!error.empty())
            return false;
        if (++values > MAX_VALUES || depth > MAX_DEPTH) {
            fail("Checkpoint nesting/value limit exceeded");
            return false;
        }
        return true;
    }
    void write(const Variant &value, unsigned depth) {
        if (!count(depth))
            return;
        if (output.size() > MAX_BYTES) {
            fail("Checkpoint byte limit exceeded");
            return;
        }
        switch (value.get_type()) {
        case Variant::NIL:
            output.push_back(0);
            break;
        case Variant::BOOL:
            output.push_back(bool(value) ? 2 : 1);
            break;
        case Variant::INT:
            output.push_back(3);
            integer(uint64_t(int64_t(value)), 8);
            break;
        case Variant::FLOAT: {
            double number = value;
            if (!std::isfinite(number)) {
                fail("Non-finite checkpoint float");
                return;
            }
            output.push_back(4);
            real(number);
            break;
        }
        case Variant::STRING:
        case Variant::STRING_NAME: {
            CharString text = String(value).utf8();
            if (text.length() > 4096) {
                fail("Checkpoint string too long");
                return;
            }
            for (int64_t i = 0; i < text.length(); ++i) {
                auto byte = uint8_t(text[i]);
                if (byte < 32 || byte > 126) {
                    fail("Checkpoint strings must contain printable ASCII");
                    return;
                }
            }
            output.push_back(5);
            integer(text.length(), 4);
            output.insert(output.end(), text.get_data(),
                          text.get_data() + text.length());
            break;
        }
        case Variant::VECTOR2I: {
            Vector2i point = value;
            output.push_back(6);
            integer(uint64_t(int64_t(point.x)), 8);
            integer(uint64_t(int64_t(point.y)), 8);
            break;
        }
        case Variant::VECTOR3I: {
            Vector3i point = value;
            output.push_back(7);
            integer(uint64_t(int64_t(point.x)), 8);
            integer(uint64_t(int64_t(point.y)), 8);
            integer(uint64_t(int64_t(point.z)), 8);
            break;
        }
        case Variant::VECTOR3: {
            Vector3 point = value;
            if (!visual || !std::isfinite(point.x) || !std::isfinite(point.y) ||
                !std::isfinite(point.z)) {
                fail("Invalid visual vector");
                return;
            }
            output.push_back(10);
            real(point.x);
            real(point.y);
            real(point.z);
            break;
        }
        case Variant::ARRAY: {
            const Array array = value;
            if (size_t(array.size()) > MAX_COLLECTION) {
                fail("Checkpoint collection too large");
                return;
            }
            output.push_back(8);
            integer(array.size(), 4);
            for (int64_t i = 0; i < array.size() && error.empty(); ++i)
                write(array[i], depth + 1);
            break;
        }
        case Variant::DICTIONARY: {
            const Dictionary source = value;
            if (size_t(source.size()) > MAX_COLLECTION) {
                fail("Checkpoint collection too large");
                return;
            }
            Array original = source.keys();
            uint32_t fingerprint = original.hash();
            std::shared_ptr<KeyLayout> layout;
            auto found = layouts.find(fingerprint);
            if (found != layouts.end()) {
                for (const auto &candidate : found->second) {
                    // Hashes only index candidates; full key equality is
                    // mandatory.
                    if (candidate->original == original) {
                        layout = candidate;
                        break;
                    }
                }
            }
            if (!layout) {
                layout = std::make_shared<KeyLayout>();
                layout->original = original;
                for (int64_t i = 0; i < original.size(); ++i) {
                    Variant key = original[i];
                    if (key.get_type() == Variant::STRING_NAME)
                        key = String(key);
                    if (key.get_type() != Variant::INT &&
                        key.get_type() != Variant::STRING) {
                        fail("Checkpoint map keys must be strings or integers");
                        return;
                    }
                    layout->keys.push_back(key);
                }
                std::sort(layout->keys.begin(), layout->keys.end(),
                          [](const Variant &a, const Variant &b) {
                              if (a.get_type() != b.get_type())
                                  return a.get_type() < b.get_type();
                              return a.get_type() == Variant::INT
                                         ? int64_t(a) < int64_t(b)
                                         : String(a) < String(b);
                          });
                size_t prefix_bytes = 0;
                for (const auto &key : layout->keys) {
                    Grammar encoder(visual);
                    encoder.write(key, 0);
                    if (!encoder.error.empty()) {
                        fail(encoder.error.c_str());
                        return;
                    }
                    prefix_bytes += encoder.output.size();
                    if (prefix_bytes > MAX_BYTES) {
                        fail("Checkpoint byte limit exceeded");
                        return;
                    }
                    layout->prefixes.push_back(std::move(encoder.output));
                }
                if (layout_count < 128 &&
                    layout_bytes + prefix_bytes <= MAX_BYTES) {
                    layouts[fingerprint].push_back(layout);
                    ++layout_count;
                    layout_bytes += prefix_bytes;
                }
            }
            output.push_back(9);
            integer(source.size(), 4);
            for (size_t i = 0; i < layout->keys.size(); ++i) {
                if (!count(depth + 1))
                    return;
                if (output.size() > MAX_BYTES) {
                    fail("Checkpoint byte limit exceeded");
                    return;
                }
                output.insert(output.end(), layout->prefixes[i].begin(),
                              layout->prefixes[i].end());
                write(source[layout->keys[i]], depth + 1);
                if (!error.empty())
                    break;
            }
            break;
        }
        default:
            fail("Unsupported checkpoint value type");
            break;
        }
    }
    bool take(size_t count) {
        if (offset > length || count > length - offset) {
            fail("Truncated checkpoint value");
            return false;
        }
        offset += count;
        return true;
    }
    uint64_t unsigned_integer(unsigned size) {
        if (!take(size))
            return 0;
        uint64_t result = 0;
        for (unsigned i = 0; i < size; ++i)
            result |= uint64_t(input[offset - size + i]) << (8 * i);
        return result;
    }
    int64_t signed_integer() {
        auto bits = unsigned_integer(8);
        int64_t result;
        std::memcpy(&result, &bits, sizeof(result));
        return result;
    }
    double read_real() {
        auto bits = unsigned_integer(8);
        double result;
        std::memcpy(&result, &bits, sizeof(result));
        if (!std::isfinite(result))
            fail("Non-finite checkpoint float");
        return result;
    }
    Variant read(unsigned depth) {
        if (!count(depth) || !take(1))
            return Variant();
        uint8_t tag = input[offset - 1];
        switch (tag) {
        case 0:
            return Variant();
        case 1:
            return false;
        case 2:
            return true;
        case 3:
            return signed_integer();
        case 4:
            return read_real();
        case 5: {
            size_t size = unsigned_integer(4);
            if (size > 4096 || !take(size)) {
                fail("Invalid checkpoint string length");
                return Variant();
            }
            const auto *start = input + offset - size;
            for (size_t i = 0; i < size; ++i)
                if (start[i] < 32 || start[i] > 126) {
                    fail("Checkpoint strings must contain printable ASCII");
                    return Variant();
                }
            std::string_view key(reinterpret_cast<const char *>(start), size);
            auto found = strings.find(key);
            if (found != strings.end())
                return found->second;
            String text = String::utf8(key.data(), key.size());
            ++strings_created;
            if (strings.size() < 256 && string_bytes + size <= 256 * 1024) {
                strings.emplace(key, text);
                string_bytes += size;
            }
            return text;
        }
        case 6:
        case 7: {
            int64_t parts[3] = {0, 0, 0};
            for (unsigned i = 0; i < (tag == 6 ? 2u : 3u); ++i) {
                parts[i] = signed_integer();
                if (parts[i] < INT32_MIN || parts[i] > INT32_MAX) {
                    fail("Vector component overflow");
                    return Variant();
                }
            }
            return tag == 6 ? Variant(Vector2i(parts[0], parts[1]))
                            : Variant(Vector3i(parts[0], parts[1], parts[2]));
        }
        case 8:
        case 9: {
            size_t size = unsigned_integer(4);
            if (size > MAX_COLLECTION) {
                fail("Checkpoint collection too large");
                return Variant();
            }
            Array array;
            Dictionary dictionary;
            for (size_t i = 0; i < size; ++i) {
                Variant key = read(depth + 1);
                if (!error.empty())
                    return Variant();
                if (tag == 9) {
                    if ((key.get_type() != Variant::INT &&
                         key.get_type() != Variant::STRING) ||
                        dictionary.has(key)) {
                        fail("Invalid or duplicate checkpoint field");
                        return Variant();
                    }
                    Variant child = read(depth + 1);
                    if (!error.empty())
                        return Variant();
                    dictionary[key] = child;
                } else
                    array.push_back(key);
            }
            return tag == 9 ? Variant(dictionary) : Variant(array);
        }
        case 10: {
            if (!visual) {
                fail("Unknown checkpoint value tag");
                return Variant();
            }
            double x = read_real(), y = read_real(), z = read_real();
            Vector3 point(x, y, z);
            if (!std::isfinite(point.x) || !std::isfinite(point.y) ||
                !std::isfinite(point.z)) {
                fail("Invalid visual vector");
                return Variant();
            }
            return point;
        }
        default:
            fail("Unknown checkpoint value tag");
            return Variant();
        }
    }
};
} // namespace
namespace bloodshot {
void BloodshotPrimitiveCodec::_bind_methods() {
    ClassDB::bind_method(D_METHOD("project_scalar_records", "values", "allowed"),
                         &BloodshotPrimitiveCodec::project_scalar_records);
    ClassDB::bind_method(D_METHOD("select_integer_records", "values", "field",
                                  "low", "high", "first"),
                         &BloodshotPrimitiveCodec::select_integer_records);
    ClassDB::bind_method(D_METHOD("apply_frozen", "before", "patch"),
                         &BloodshotPrimitiveCodec::apply_frozen);
    ClassDB::bind_method(D_METHOD("freeze_tree", "value"),
                         &BloodshotPrimitiveCodec::freeze_tree);
    ClassDB::bind_method(D_METHOD("difference", "before", "after"),
                         &BloodshotPrimitiveCodec::difference);
    ClassDB::bind_method(D_METHOD("compress_payload", "bytes", "level"),
                         &BloodshotPrimitiveCodec::compress_payload);
    ClassDB::bind_method(D_METHOD("decompress_payload", "bytes", "expected"),
                         &BloodshotPrimitiveCodec::decompress_payload);
    ClassDB::bind_method(
        D_METHOD("validate_scalar_records", "values", "rules", "required"),
        &BloodshotPrimitiveCodec::validate_scalar_records);
    ClassDB::bind_method(D_METHOD("encode_payload", "value", "visual"),
                         &BloodshotPrimitiveCodec::encode_payload);
    ClassDB::bind_method(D_METHOD("decode_payload", "bytes", "visual"),
                         &BloodshotPrimitiveCodec::decode_payload);
}
// Projection only: schema/range validation stays at its existing boundary. The
// caller supplies reviewed public field names; source scalar values retain their
// exact Variant types and ordering. Each output record is separately writable.
Array BloodshotPrimitiveCodec::project_scalar_records(
    const Array &values, const Dictionary &allowed) const {
    Array result;
    if (values.size() > int64_t(MAX_COLLECTION) ||
        allowed.size() > int64_t(MAX_COLLECTION))
        return result;
    result.resize(values.size());
    for (int64_t i = 0; i < values.size(); ++i) {
        if (values[i].get_type() != Variant::DICTIONARY)
            return Array();
        const Dictionary source = values[i];
        Dictionary row;
        Array keys = source.keys();
        if (keys.size() > int64_t(MAX_COLLECTION))
            return Array();
        for (int64_t j = 0; j < keys.size(); ++j) {
            const Variant key = keys[j];
            if (allowed.has(key))
                row[key] = source[key];
        }
        result[i] = row;
    }
    return result;
}
// Compile the locally supplied scalar ranges once for the entire actor batch.
// Required/optional fields, integer types, legacy bools and unknown/private
// keys have exactly the same disposition as CheckpointSchema._record. No
// coercion.
bool BloodshotPrimitiveCodec::validate_scalar_records(
    const Array &values, const Dictionary &rules, const Array &required) const {
    if (values.size() > 8192 || rules.size() > 8192 ||
        required.size() > rules.size())
        return false;
    struct Rule {
        int64_t low, high;
        bool bool_int;
    };
    std::vector<Rule> compiled;
    Dictionary indexes;
    Array names = rules.keys();
    for (int64_t i = 0; i < names.size(); ++i) {
        Variant name = names[i], raw = rules[name];
        if ((name.get_type() != Variant::STRING &&
             name.get_type() != Variant::STRING_NAME) ||
            raw.get_type() != Variant::DICTIONARY)
            return false;
        const Dictionary rule = raw;
        if (rule.size() != 3 || !rule.has("low") || !rule.has("high") ||
            !rule.has("bool_int"))
            return false;
        Variant low = rule["low"], high = rule["high"],
                boolean = rule["bool_int"];
        if (low.get_type() != Variant::INT || high.get_type() != Variant::INT ||
            boolean.get_type() != Variant::BOOL || int64_t(low) > int64_t(high))
            return false;
        indexes[name] = int64_t(compiled.size());
        compiled.push_back({int64_t(low), int64_t(high), bool(boolean)});
    }
    for (int64_t i = 0; i < required.size(); ++i)
        if (!indexes.has(required[i]))
            return false;
    for (int64_t i = 0; i < values.size(); ++i) {
        Variant raw = values[i];
        if (raw.get_type() != Variant::DICTIONARY)
            return false;
        const Dictionary row = raw;
        for (int64_t j = 0; j < required.size(); ++j)
            if (!row.has(required[j]))
                return false;
        Array keys = row.keys();
        for (int64_t j = 0; j < keys.size(); ++j) {
            Variant key = keys[j];
            if ((key.get_type() != Variant::STRING &&
                 key.get_type() != Variant::STRING_NAME) ||
                !indexes.has(key))
                return false;
            const auto &rule = compiled[int64_t(indexes[key])];
            Variant value = row[key];
            if (rule.bool_int && value.get_type() == Variant::BOOL)
                continue;
            if (value.get_type() != Variant::INT || int64_t(value) < rule.low ||
                int64_t(value) > rule.high)
                return false;
        }
    }
    return true;
}
namespace {
Variant detached(const Variant &value) {
    if (value.get_type() == Variant::DICTIONARY)
        return Dictionary(value).duplicate(true);
    if (value.get_type() == Variant::ARRAY)
        return Array(value).duplicate(true);
    return value;
}
Variant apply_shared(const Variant &before, const Dictionary &patch,
                     unsigned depth, String &error) {
    if (depth > MAX_DEPTH) {
        error = "Patch nesting limit";
        return Variant();
    }
    if (patch.is_empty())
        return before;
    Variant op = patch.get("op", Variant());
    if (op == Variant("set") && patch.size() == 2 && patch.has("value"))
        return detached(patch["value"]);
    Variant items_raw = patch.get("items", Variant());
    bool map = op == Variant("map") && patch.size() == 3 &&
               before.get_type() == Variant::DICTIONARY;
    bool list = op == Variant("array") && patch.size() == 2 &&
                before.get_type() == Variant::ARRAY;
    if (items_raw.get_type() != Variant::DICTIONARY || (!map && !list)) {
        error = "Invalid patch shape";
        return Variant();
    }
    const Dictionary items = items_raw;
    Dictionary result_map;
    Array result_list;
    if (map) {
        Variant removed = patch.get("remove", Variant());
        if (removed.get_type() != Variant::ARRAY) {
            error = "Invalid patch shape";
            return Variant();
        }
        result_map = Dictionary(before).duplicate(false);
        const Array keys = removed;
        for (int64_t i = 0; i < keys.size(); ++i) {
            Variant key = keys[i];
            if (!result_map.has(key) || items.has(key)) {
                error = "Invalid explicit removal";
                return Variant();
            }
            result_map.erase(key);
        }
    } else
        result_list = Array(before).duplicate(false);
    Array keys = items.keys();
    for (int64_t i = 0; i < keys.size(); ++i) {
        Variant key = keys[i], raw = items[key];
        if (raw.get_type() != Variant::DICTIONARY ||
            (list && (key.get_type() != Variant::INT || int64_t(key) < 0 ||
                      int64_t(key) >= result_list.size()))) {
            error = "Invalid changed-field index";
            return Variant();
        }
        Variant child = apply_shared(map ? result_map.get(key, Variant())
                                         : result_list[int64_t(key)],
                                     raw, depth + 1, error);
        if (!error.is_empty())
            return Variant();
        if (map)
            result_map[key] = child;
        else
            result_list[int64_t(key)] = child;
    }
    return map ? Variant(result_map) : Variant(result_list);
}
} // namespace
Dictionary
BloodshotPrimitiveCodec::apply_frozen(const Variant &before,
                                      const Dictionary &patch) const {
    String error;
    Variant value = apply_shared(before, patch, 0, error);
    Dictionary result;
    result["value"] = error.is_empty() ? value : Variant();
    result["error"] = error;
    return result;
}
// Generic stable index selection over locally validated scalar records. No
// collision, clocks, actors or rules are implemented/cached here. Callers
// supply bounds and consume current source records at their original
// indices/order.
PackedInt32Array BloodshotPrimitiveCodec::select_integer_records(
    const Array &values, const String &field, int64_t low, int64_t high,
    int64_t first) const {
    PackedInt32Array result;
    if (values.size() > int64_t(MAX_COLLECTION) || first < 0 ||
        first > values.size())
        return result;
    for (int64_t i = first; i < values.size(); ++i) {
        Variant raw = values[i];
        if (raw.get_type() != Variant::DICTIONARY)
            continue;
        Variant value = Dictionary(raw).get(field, Variant());
        if (value.get_type() == Variant::INT && int64_t(value) >= low &&
            int64_t(value) <= high)
            result.push_back(i);
    }
    return result;
}
// Local validated snapshots only. Recursively frozen shared actor/path caches
// are visited once, then skipped. This never handles remote/unvalidated values.
void BloodshotPrimitiveCodec::freeze_tree(const Variant &value) const {
    if (value.get_type() == Variant::DICTIONARY) {
        Dictionary row = value;
        if (row.is_read_only())
            return;
        Array keys = row.keys();
        for (int64_t i = 0; i < keys.size(); ++i)
            freeze_tree(row[keys[i]]);
        row.make_read_only();
    } else if (value.get_type() == Variant::ARRAY) {
        Array items = value;
        if (items.is_read_only())
            return;
        for (int64_t i = 0; i < items.size(); ++i)
            freeze_tree(items[i]);
        items.make_read_only();
    }
}
// Local, bounded public trees only: same recursive patch operations as the
// portable oracle. Remote patch validation/application remains mandatory. A
// depth/value overflow uses a complete replacement, never a partial delta.
namespace {
Dictionary diff(const Variant &before, const Variant &after, unsigned depth,
                size_t &visited) {
    if (++visited > MAX_VALUES || depth > MAX_DEPTH) {
        Dictionary patch;
        patch["op"] = "set";
        patch["value"] = after;
        return patch;
    }
    if (before.get_type() == after.get_type() && before == after)
        return Dictionary();
    Dictionary patch;
    if (before.get_type() == Variant::DICTIONARY &&
        after.get_type() == Variant::DICTIONARY) {
        const Dictionary old = before, next = after;
        Dictionary items;
        Array removed, keys = old.keys();
        for (int64_t i = 0; i < keys.size(); ++i)
            if (!next.has(keys[i]))
                removed.push_back(keys[i]);
        keys = next.keys();
        for (int64_t i = 0; i < keys.size(); ++i) {
            Variant key = keys[i];
            Dictionary child;
            if (old.has(key))
                child = diff(old[key], next[key], depth + 1, visited);
            else {
                child["op"] = "set";
                child["value"] = next[key];
            }
            if (!child.is_empty())
                items[key] = child;
        }
        patch["op"] = "map";
        patch["remove"] = removed;
        patch["items"] = items;
        return patch;
    }
    if (before.get_type() == Variant::ARRAY &&
        after.get_type() == Variant::ARRAY) {
        const Array old = before, next = after;
        bool receipts = false;
        if (next.size() > 8 && next[0].get_type() == Variant::DICTIONARY) {
            const Dictionary row = next[0];
            receipts =
                row.size() == 2 && row.has("sequence") && row.has("ordinal");
        }
        if (old.size() == next.size() && !receipts) {
            Dictionary items;
            for (int64_t i = 0; i < next.size(); ++i) {
                Dictionary child = diff(old[i], next[i], depth + 1, visited);
                if (!child.is_empty())
                    items[i] = child;
            }
            patch["op"] = "array";
            patch["items"] = items;
            return patch;
        }
    }
    patch["op"] = "set";
    patch["value"] = after;
    return patch;
}
} // namespace
Dictionary BloodshotPrimitiveCodec::difference(const Variant &before,
                                               const Variant &after) const {
    size_t visited = 0;
    return diff(before, after, 0, visited);
}
// Standard Zstd framing, with explicit output/window caps and no engine errors
// for malformed remote bytes. Inner primitive framing/SHA is still mandatory.
Dictionary
BloodshotPrimitiveCodec::compress_payload(const PackedByteArray &bytes,
                                          int level) const {
    Dictionary result;
    PackedByteArray output;
    String error;
    if (bytes.size() > int64_t(MAX_BYTES) || level < 1 || level > 9) {
        error = "Invalid compression bounds";
    } else {
        output.resize(ZSTD_compressBound(bytes.size()));
        size_t size = ZSTD_compress(output.ptrw(), output.size(), bytes.ptr(),
                                    bytes.size(), level);
        if (ZSTD_isError(size)) {
            error = "Compression failed";
            output.clear();
        } else
            output.resize(size);
    }
    result["bytes"] = output;
    result["error"] = error;
    return result;
}
Dictionary
BloodshotPrimitiveCodec::decompress_payload(const PackedByteArray &bytes,
                                            int expected) const {
    Dictionary result;
    PackedByteArray output;
    String error;
    if (expected < 1 || expected > int(MAX_BYTES) ||
        bytes.size() > int64_t(MAX_BYTES) ||
        ZSTD_getFrameContentSize(bytes.ptr(), bytes.size()) !=
            uint64_t(expected) ||
        ZSTD_findFrameCompressedSize(bytes.ptr(), bytes.size()) !=
            size_t(bytes.size())) {
        error = "Invalid compressed payload bounds/frame";
    } else {
        ZSTD_DCtx *context = ZSTD_createDCtx();
        if (!context) {
            error = "Cannot allocate bounded decompressor";
        } else {
            size_t configured =
                ZSTD_DCtx_setParameter(context, ZSTD_d_windowLogMax, 21);
            output.resize(expected);
            size_t size =
                ZSTD_isError(configured)
                    ? configured
                    : ZSTD_decompressDCtx(context, output.ptrw(), output.size(),
                                          bytes.ptr(), bytes.size());
            if (ZSTD_isError(size) || size != size_t(expected)) {
                error = "Invalid compressed payload";
                output.clear();
            }
            ZSTD_freeDCtx(context);
        }
    }
    result["bytes"] = output;
    result["error"] = error;
    return result;
}
Dictionary BloodshotPrimitiveCodec::encode_payload(const Dictionary &value,
                                                   bool visual) const {
    Grammar grammar(visual);
    grammar.output.reserve(65536);
    grammar.write(value, 0);
    if (grammar.output.size() > MAX_BYTES)
        grammar.fail("Checkpoint byte limit exceeded");
    PackedByteArray bytes;
    if (grammar.error.empty()) {
        bytes.resize(grammar.output.size());
        std::memcpy(bytes.ptrw(), grammar.output.data(), grammar.output.size());
    }
    Dictionary result;
    result["bytes"] = bytes;
    result["error"] = String(grammar.error.c_str());
    result["values"] = int64_t(grammar.values);
    return result;
}
Dictionary BloodshotPrimitiveCodec::decode_payload(const PackedByteArray &bytes,
                                                   bool visual) const {
    Grammar grammar(visual);
    grammar.input = bytes.ptr();
    grammar.length = bytes.size();
    if (grammar.length > MAX_BYTES)
        grammar.fail("Invalid checkpoint length");
    Variant value = grammar.read(0);
    if (grammar.offset != grammar.length ||
        value.get_type() != Variant::DICTIONARY)
        grammar.fail("Trailing data or invalid checkpoint root");
    Dictionary result;
    result["value"] = grammar.error.empty() ? value : Variant(Dictionary());
    result["error"] = String(grammar.error.c_str());
    result["values"] = int64_t(grammar.values);
    result["offset"] = int64_t(grammar.offset);
    result["strings_created"] = int64_t(grammar.strings_created);
    result["string_cache_entries"] = int64_t(grammar.strings.size());
    return result;
}
} // namespace bloodshot
