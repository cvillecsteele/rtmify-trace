LIB_DIR  = lib
ZIG_DIR  = ../librtmify
SCHEME   = RTMify Trace
PROJECT  = RTMify Trace.xcodeproj

.PHONY: lib build clean dmg build-universal

lib: $(LIB_DIR)/librtmify.a

$(LIB_DIR)/librtmify.a:
	mkdir -p $(LIB_DIR)
	cd $(ZIG_DIR) && zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
	cp $(ZIG_DIR)/zig-out/lib/librtmify.a $(LIB_DIR)/librtmify.a

build-universal:
	mkdir -p $(LIB_DIR)
	cd $(ZIG_DIR) && zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
	cp $(ZIG_DIR)/zig-out/lib/librtmify.a $(LIB_DIR)/librtmify-arm64.a
	cd $(ZIG_DIR) && zig build -Dtarget=x86_64-macos  -Doptimize=ReleaseSafe
	cp $(ZIG_DIR)/zig-out/lib/librtmify.a $(LIB_DIR)/librtmify-x64.a
	lipo -create $(LIB_DIR)/librtmify-arm64.a $(LIB_DIR)/librtmify-x64.a \
	     -output $(LIB_DIR)/librtmify.a

build: lib
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
	           -configuration Release -derivedDataPath .build

clean:
	rm -rf $(LIB_DIR) .build
