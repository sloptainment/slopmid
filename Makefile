# make [linux] [windows] [all]. Windows needs SDL2_MINGW=<SDL2 mingw dev package>/x86_64-w64-mingw32
NIM = nim cpp -d:release --passL:-s # -s: strip all symbols

.PHONY: all linux windows
all: linux windows

linux:
	$(NIM) --nimcache:nimcache/linux -o:slopmid src/slopmid.nim

windows:
	$(if $(SDL2_MINGW),,$(error set SDL2_MINGW to SDL2's x86_64-w64-mingw32 directory))
	$(NIM) -d:win64 --nimcache:nimcache/windows -o:slopmid.exe src/slopmid.nim
