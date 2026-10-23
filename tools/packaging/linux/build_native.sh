#!/bin/sh
# All mounted sources/bindings are read-only. Only /output is persistent writable.
set -eu
target="$1"
jobs="$2"
cmake -S /zstd/build/cmake -B /output/codecs/zstd \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_C_FLAGS='-ffile-prefix-map=/zstd=zstd -ffile-prefix-map=/chdr=libchdr' \
  -DCMAKE_INSTALL_PREFIX=/output/codecs/install -DZSTD_BUILD_PROGRAMS=OFF \
  -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON \
  -DZSTD_MULTITHREAD_SUPPORT=OFF
cmake --build /output/codecs/zstd --parallel "$jobs"
cmake --install /output/codecs/zstd
cmake -S /chdr -B /output/codecs/chdr \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_C_FLAGS='-ffile-prefix-map=/zstd=zstd -ffile-prefix-map=/chdr=libchdr' \
  -DCMAKE_PREFIX_PATH=/output/codecs/install -DBUILD_SHARED_LIBS=OFF \
  -DWITH_SYSTEM_ZSTD=ON -DWITH_SYSTEM_ZLIB=OFF -DWITH_LZMA_ASM=OFF
cmake --build /output/codecs/chdr --target chdr-static --parallel "$jobs"
make -C /source/native/audio --no-print-directory -j"$jobs" \
  "TARGET=$target" GODOT_CPP=/godot-cpp YMFM=/ymfm GEN=/bindings \
  "BUILD=/output/$target/objects" "OUT=/output/$target/native.so" SOURCE_ROOT=/source \
  'CODEC_INCLUDES=-I/chdr/include -I/output/codecs/install/include' \
  'CODEC_LIBS=/output/codecs/chdr/libchdr-static.a /output/codecs/chdr/deps/lzma-25.01/libchdr-lzma.a /output/codecs/chdr/deps/miniz-3.1.1/libminiz.a /output/codecs/install/lib/libzstd.a' \
  'EXTRA_PREFIX_MAP=-ffile-prefix-map=/godot-cpp=godot-cpp -ffile-prefix-map=/bindings=bindings -ffile-prefix-map=/ymfm=ymfm'
cp /usr/share/bloodshot-baseline-packages.txt /output/packages.txt
gcc --version > /output/compiler.txt
getconf GNU_LIBC_VERSION > /output/glibc.txt
