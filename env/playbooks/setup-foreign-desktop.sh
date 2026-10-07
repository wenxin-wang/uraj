#!/bin/sh
# Run the foreign-desktop playbook on this machine: the host layer
# (apt packages, /etc files, GDM, udev) that the Guix Home environment
# does not cover.  Extra arguments go to ansible-playbook.
set -eu

repo="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$repo"

# sudo keeps LANG/LC_* but drops GUIX_LOCPATH, so Guix's Python under
# become cannot resolve the session locale and Gathering Facts dies
# with "unsupported locale setting".  LC_ALL overrides all LC_* (LANG
# covers a strip of LC_ALL); C.UTF-8 is built into both glibcs.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Run modules with the system Python, not Guix's.  The apt module asks
# the system "locale -a" for a parsable locale, gets "C.utf8", and then
# setlocale()s to it -- which Guix's glibc rejects with the same
# "unsupported locale setting" error.  The system Python resolves it and
# also has python-apt, which apt needs.  Our -e goes first so a -e from
# the user still wins.
exec ansible-playbook -e ansible_python_interpreter=/usr/bin/python3 \
    -K env/playbooks/foreign-desktop.yml "$@"
