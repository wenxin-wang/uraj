# contained-agent 里浏览器的显示

- Display: as in the OpenClaw sandbox, Chromium runs headed in a private
  cage on wlroots' headless backend, one per browser, which exits with it:
  headless mode changes what sites see, and Xvfb cannot use the GPU.  The
  `contained-chromium` wrapper composites with Vulkan on the render node,
  and WebGL uses ANGLE on Mesa's hardware drivers with software rendering
  refused, so a broken GPU path shows as missing WebGL.  Without a render
  node it uses pixman and SwiftShader.  Their stderr goes to
  `~/.browser-profile/runtime/browser-PID.log`, not to agent-browser, which
  reads it only after startup: cage's Vulkan logging would fill the pipe
  and block before Chromium starts.  Fonts are Noto (including CJK and
  emoji) and Liberation.  Podman runtime sessions get neither the snapshots
  nor the GPU yet.
