/* nimgl's vendored GLFW is a 3.4 pre-release (3.3-357-g94773111) that reports
   3.4 but predates glfwGetPlatform(), which imgui_impl_glfw.cpp calls on 3.4.
   nimgl builds only GLFW's X11 backend, so X11 is the true answer. */
#include <GLFW/glfw3.h>
#define GLFW_PLATFORM_WAYLAND 0x00060003
#define GLFW_PLATFORM_X11 0x00060004
static inline int glfwGetPlatform(void) { return GLFW_PLATFORM_X11; }
