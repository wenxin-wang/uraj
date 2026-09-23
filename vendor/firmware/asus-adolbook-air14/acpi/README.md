# ASUS Adol Book Air 14 (M5451GA) ACPI tables

`SSDT10.aml` is the unmodified firmware table of this laptop, dumped on the
machine and vendored here so that the fix built from it stays reproducible
and reviewable:

    sha256  91114b70f98961d7437368e8302a6a5a9dd39e295a7837f77b1b8ddd28337d01
    header  SSDT, 7040 bytes, OEM ID "AMD\0\0\0", OEM table ID "AOD     ",
            OEM revision 1, compiler INTL 20230331

The complete 43-table dump lives next to the analysis in
`~/tmp/asus-adolbook-air14-acpi/SSDTTime-Results/OEM/`; its `FINDINGS.md`
records how the tables were extracted, what was tried, and the validation of
the fix with acpiexec.

## Why this table has to be replaced

Loading it panics the kernel.  SSDT10 re-declares the root names `ASMI` and
`ISMI` that the DSDT already defines as methods, so ACPICA cannot create
them; the `OperationRegion (PSMI, SystemIO, ASMI, 0x02)` that uses them is
then left without a region object, and `acpi_ex_prep_field_value()`
dereferences the null pointer.  The panic happens in `acpi_init`, before the
keyboard, touchpad or graphics ever come up: `acpi=off` is the only way past
it, and that kills the internal keyboard too (its PS/2 port is only enabled
by the EC once ACPI says so).

## The fix

The patch `src/guix/uraj/packages/patches/asus-adolbook-air14-ssdt10.patch`
deletes the two colliding names, inlines the constants where SSDT10 used them
(`0x00B2`, `0xB9`) and bumps the OEM revision to 2.  `(uraj packages asus)`
applies it to this dump (`iasl -d`, `patch`, `iasl -tc`) and
`(uraj hardware asus)` prepends the result to the initrd, where the kernel's
initrd table override replaces the firmware's copy of the table.  That
mechanism matches a table by signature + OEM ID + OEM table ID, all of which
the patch leaves alone, and only replaces a firmware table whose OEM revision
is lower -- hence the bump.  It is disabled under kernel lockdown (so do not
enable Secure Boot while relying on this).
