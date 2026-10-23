#!/usr/bin/env python3
"""Generate godot-cpp's C++ bindings for the audio extension.

Called by tools/bin/build-audio (not by SCons): runs godot-cpp's own generator
on its extension_api-<API>.json, trimmed by our build_profile.json, and writes
<out>/gen/{include,src}. Usage:

    gen_bindings.py GODOT_CPP_DIR API_VERSION BUILD_PROFILE OUT_DIR

Part of mightyweenie (BSD-3-Clause, see LICENSE).
"""
import sys
from pathlib import Path


def main() -> int:
    godot_cpp, api_version, profile, out_dir = sys.argv[1:5]
    godot_cpp = Path(godot_cpp).resolve()
    sys.path.insert(0, str(godot_cpp))  # binding_generator.py, build_profile.py
    from binding_generator import _generate_bindings  # noqa: E402 (godot-cpp)
    from build_profile import generate_trimmed_api  # noqa: E402 (godot-cpp)

    ext_dir = godot_cpp / "gdextension"
    api_file = ext_dir / ("extension_api-%s.json" % api_version.replace(".", "-"))
    interface_file = ext_dir / "gdextension_interface.json"
    api = generate_trimmed_api(str(api_file), str(Path(profile).resolve()))
    # (api, api file, interface file, template get_node, bits, precision, output dir, hooks)
    _generate_bindings(api, str(api_file), str(interface_file), False, "64", "single", out_dir, None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
