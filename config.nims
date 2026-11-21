--backend:cpp

# SDL2's flags. Windows: nim cpp -d:win64 src/slopmid.nim, with SDL2_MINGW set to the
# x86_64-w64-mingw32 directory of SDL2's mingw development package.
if defined(win64):
  switch("os", "windows")
  switch("cpu", "amd64")
  switch("gcc.exe", "x86_64-w64-mingw32-gcc")
  switch("gcc.cpp.exe", "x86_64-w64-mingw32-g++")
  switch("gcc.linkerexe", "x86_64-w64-mingw32-g++")
  switch("gcc.cpp.linkerexe", "x86_64-w64-mingw32-g++")
  switch("gcc.options.linker", "") # nim.cfg has already added the host's -ldl
  switch("gcc.cpp.options.linker", "")
  switch("passC", "-I" & getEnv("SDL2_MINGW") & "/include/SDL2")
  switch("passL", "-L" & getEnv("SDL2_MINGW") & "/lib -lSDL2")
else:
  switch("passC", gorge("sdl2-config --cflags"))
  switch("passL", gorge("sdl2-config --libs"))
