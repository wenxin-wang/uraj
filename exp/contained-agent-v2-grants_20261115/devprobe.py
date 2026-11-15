"""Open a device node and issue one harmless ioctl.

Usage: devprobe.py PATH kvm|drm

kvm: KVM_GET_API_VERSION, then KVM_CREATE_VM (a VM fd proves KVM works).
drm: DRM_IOCTL_VERSION, printing the driver name.
"""

import ctypes
import fcntl
import os
import sys

KVM_GET_API_VERSION = 0xAE00
KVM_CREATE_VM = 0xAE01
DRM_IOCTL_VERSION = 0xC0406400


class DrmVersion(ctypes.Structure):
    _fields_ = [
        ("major", ctypes.c_int),
        ("minor", ctypes.c_int),
        ("patch", ctypes.c_int),
        ("name_len", ctypes.c_size_t),
        ("name", ctypes.c_void_p),
        ("date_len", ctypes.c_size_t),
        ("date", ctypes.c_void_p),
        ("desc_len", ctypes.c_size_t),
        ("desc", ctypes.c_void_p),
    ]


def main():
    path, kind = sys.argv[1], sys.argv[2]
    try:
        fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
    except OSError as e:
        sys.exit(f"open: {e.strerror}")
    try:
        if kind == "kvm":
            api = fcntl.ioctl(fd, KVM_GET_API_VERSION)
            vm = fcntl.ioctl(fd, KVM_CREATE_VM, 0)
            print(f"api {api}, created VM fd {vm}")
        else:
            v = DrmVersion()
            fcntl.ioctl(fd, DRM_IOCTL_VERSION, v)
            name = ctypes.create_string_buffer(v.name_len + 1)
            v.name = ctypes.addressof(name)
            v.date_len = v.desc_len = 0
            fcntl.ioctl(fd, DRM_IOCTL_VERSION, v)
            print(f"driver {name.value.decode()} {v.major}.{v.minor}")
    except OSError as e:
        sys.exit(f"ioctl: {e.strerror}")


if __name__ == "__main__":
    main()
