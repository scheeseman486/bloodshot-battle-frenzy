# mightyweenie - audio GDExtension (native/mw_audio).
# Copyright (c) 2026 the mightyweenie authors. BSD-3-Clause
# (see LICENSE).
#
# Adapted for Bloodshot. tools/build_audio.py fetches pinned dependencies,
# generates trimmed Godot 4.7 bindings and passes private BUILD/GEN/OUT paths.
# Linux and MinGW Windows x86_64 use separate object and dependency trees.
# Outputs are installed atomically so active editors retain their mapped binary.

PLATFORM ?= linux
TARGET ?= template_debug
CXX ?= g++
AR ?= ar
# (build/<platform>.<target>.x86_64/ from before the relative paths holds .d
# files with one machine's absolute paths: unused, safe to delete.)
BUILD := build/$(PLATFORM)-$(TARGET)-x86_64

DEFINES := -DGDEXTENSION -DTHREADS_ENABLED -DNDEBUG
SOURCE_ROOT ?= $(abspath ../..)
# Error macros retain __FILE__ even in release libraries. Keep developer paths
# out of shipped binaries as well as debug metadata.
CXXFLAGS := -std=c++17 -fno-exceptions -fvisibility=hidden -Wwrite-strings -ffile-prefix-map=$(SOURCE_ROOT)=. $(EXTRA_PREFIX_MAP)
LDFLAGS := -shared -fvisibility=hidden -s
CODEC_LIBS ?= -lchdr -lzstd
SYSTEM_LIBS := -pthread
CODEC_INCLUDES ?=
ifeq ($(TARGET),template_debug)
  DEFINES += -DDEBUG_ENABLED
  CXXFLAGS += -O2
else
  CXXFLAGS += -O3
endif
ifeq ($(PLATFORM),windows)
  # MinGW with static codecs, C++ runtime and POSIX thread runtime.
  DEFINES += -DWINDOWS_ENABLED
  CXXFLAGS += -m64 -march=x86-64
  LDFLAGS += -m64 -static -static-libgcc -static-libstdc++ -Wl,--no-undefined
else
  DEFINES += -DLINUX_ENABLED -DUNIX_ENABLED
  SYSTEM_LIBS += -ldl
  # GCC unique static symbols pin a DSO until process exit, after Godot has
  # destroyed its StringName table. Match godot-cpp's unload-safe Linux flag.
  CXXFLAGS += -fPIC -m64 -march=x86-64 -fno-gnu-unique
  LDFLAGS += -m64 -march=x86-64
  # --exclude-libs: the static C++ runtime's symbols stay private (only the
  # entry point is exported).
  LDFLAGS += -Wl,--no-undefined -Wl,-R,'$$ORIGIN' -static-libgcc -static-libstdc++ -Wl,--exclude-libs,ALL
endif

# Third-party headers as system headers: our warning flags stay on our code.
INCLUDES := -isystem $(GODOT_CPP)/include -isystem $(GEN)/gen/include -isystem $(YMFM)/src -Isrc -I../runtime $(CODEC_INCLUDES)
WARN_OURS := -Wall -Wextra

GODOT_CPP_SRC := $(wildcard $(GODOT_CPP)/src/*.cpp $(GODOT_CPP)/src/*/*.cpp)
GEN_SRC := $(shell find $(GEN)/gen/src -name '*.cpp' 2>/dev/null)
# ymfm_opn.cpp also holds the other OPN chips, which use the SSG and ADPCM engines.
YMFM_SRC := $(addprefix $(YMFM)/src/,ymfm_opn.cpp ymfm_ssg.cpp ymfm_adpcm.cpp)
OUR_SRC := $(wildcard src/*.cpp)
RUNTIME_SRC := $(wildcard ../runtime/*.cpp)

GODOT_CPP_OBJ := $(patsubst $(GODOT_CPP)/src/%.cpp,$(BUILD)/godot-cpp/%.o,$(GODOT_CPP_SRC)) \
                 $(patsubst $(GEN)/gen/src/%.cpp,$(BUILD)/gen/%.o,$(GEN_SRC))
YMFM_OBJ := $(patsubst $(YMFM)/src/%.cpp,$(BUILD)/ymfm/%.o,$(YMFM_SRC))
OUR_OBJ := $(patsubst src/%.cpp,$(BUILD)/mw/%.o,$(OUR_SRC)) \
           $(patsubst ../runtime/%.cpp,$(BUILD)/runtime/%.o,$(RUNTIME_SRC))
GODOT_CPP_LIB := $(BUILD)/libgodot-cpp.a

COMPILE = @mkdir -p $(dir $@) && echo "  CXX $(notdir $<)" && \
	$(CXX) $(DEFINES) $(INCLUDES) $(CXXFLAGS) $(1) -MMD -MP -MF $(@:.o=.d) -MT $@ -c $< -o $@.tmp && mv -f $@.tmp $@

.PHONY: all
all: $(OUT)

$(BUILD)/godot-cpp/%.o: $(GODOT_CPP)/src/%.cpp
	$(call COMPILE,)
$(BUILD)/gen/%.o: $(GEN)/gen/src/%.cpp
	$(call COMPILE,)
$(BUILD)/ymfm/%.o: $(YMFM)/src/%.cpp
	$(call COMPILE,)
$(BUILD)/runtime/%.o: ../runtime/%.cpp
	$(call COMPILE,$(WARN_OURS))
$(BUILD)/mw/%.o: src/%.cpp
	$(call COMPILE,$(WARN_OURS))

$(GODOT_CPP_OBJ) $(YMFM_OBJ) $(OUR_OBJ): Makefile

$(GODOT_CPP_LIB): $(GODOT_CPP_OBJ)
	@echo "  AR  $(notdir $@)"
	@$(AR) rcs $@.tmp $^ && mv -f $@.tmp $@

$(OUT): $(OUR_OBJ) $(YMFM_OBJ) $(GODOT_CPP_LIB) Makefile
	@mkdir -p $(dir $@)
	@echo "  LD  $(notdir $@)"
	@$(CXX) $(LDFLAGS) -o $(dir $@)tmp-$(notdir $@) $(OUR_OBJ) $(YMFM_OBJ) $(GODOT_CPP_LIB) $(CODEC_LIBS) $(SYSTEM_LIBS) && \
		mv -f $(dir $@)tmp-$(notdir $@) $@

-include $(GODOT_CPP_OBJ:.o=.d) $(YMFM_OBJ:.o=.d) $(OUR_OBJ:.o=.d)
