.PHONY: build build-arm64 clean

# Build rtmify-trace.exe for x86_64 Windows (cross-compile from any host)
build:
	cd ../librtmify && zig build win-gui -Dtarget=x86_64-windows -Doptimize=ReleaseSafe

# Build rtmify-trace.exe for ARM64 Windows
build-arm64:
	cd ../librtmify && zig build win-gui -Dtarget=aarch64-windows -Doptimize=ReleaseSafe

clean:
	cd ../librtmify && rm -rf zig-out .zig-cache

# Output: ../librtmify/zig-out/bin/rtmify-trace.exe
