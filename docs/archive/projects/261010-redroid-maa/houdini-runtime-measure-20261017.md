# Houdini 的运行验证和遗留检查

The same HPE library on the Codysk Android 13 base passed account login,
a short TR-1 battle-loading test and MAA daily tasks on 2026-10-17. The
unmodified Codysk NDK image and earlier ChromeOS Houdini 11 failed startup.
The official Android 13 base with this HPE payload completed three initial
launch observations without native crashes; the first and third reached
resource selection. The daily validation above subsequently confirmed login
and MAA on production; battle was not repeated on that base. The
first official trial exposed the missed `class_start main` hook; the helper
was then applied manually and successfully invoked through init. The fixed
boot hook still needs a full production restart check. The production
package additionally omits host-global binfmt registration; it does not
change the library binaries. These limits remain explicit even though this
configuration now replaces the trial setup.
