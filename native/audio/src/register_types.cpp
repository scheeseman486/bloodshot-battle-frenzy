#include "cdda_stream.h"
#include "chd_disc.h"
#include "fm_stream.h"
#include "mw_chips.h"
#include "primitive_codec.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#if defined(__linux__)
#include <dlfcn.h>
#endif
using namespace godot;
static void initialize(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE)
        return;
    GDREGISTER_CLASS(bloodshot::BloodshotPrimitiveCodec);
    GDREGISTER_CLASS(mw::MwChips);
    GDREGISTER_CLASS(bloodshot::BloodshotFmPlayback);
    GDREGISTER_CLASS(bloodshot::BloodshotFmStream);
    GDREGISTER_CLASS(bloodshot::BloodshotDisc);
    GDREGISTER_CLASS(bloodshot::BloodshotCddaPlayback);
    GDREGISTER_CLASS(bloodshot::BloodshotCddaStream);
}
static void uninitialize(ModuleInitializationLevel level) {
#if defined(__linux__)
    if (level == MODULE_INITIALIZATION_LEVEL_SCENE &&
        (bloodshot::BloodshotCddaPlayback::live_instances() ||
         bloodshot::BloodshotFmPlayback::live_instances())) {
        // A forced engine quit can bypass the application's mixer drain.
        // Retained AudioServer callbacks must never point into an unloaded DSO.
        // Normal application exits retire every playback and do not pin it.
        Dl_info own_library{};
        if (dladdr(reinterpret_cast<void *>(&uninitialize), &own_library))
            dlopen(own_library.dli_fname, RTLD_NOW | RTLD_NODELETE);
    }
#else
    (void)level;
#endif
}
extern "C" GDExtensionBool GDE_EXPORT bloodshot_audio_init(
    GDExtensionInterfaceGetProcAddress get_proc, GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc, library, initialization);
    init.register_initializer(initialize);
    init.register_terminator(uninitialize);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
