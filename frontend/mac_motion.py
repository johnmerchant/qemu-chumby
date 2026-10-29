# SPDX-License-Identifier: GPL-2.0-or-later
"""The motion sensor of an Apple-silicon Mac laptop, for chumby-emu.

The accelerometer in the base of these Macs is a HID device on Apple's
vendor usage page (0xFF00, usage 3), behind an AppleSPUHIDDriver service
that streams reports once its reporting and power properties are set.
Each 22-byte report carries X, Y and Z as little-endian int32 at offset
6, in 1/65536 g. None of this is documented by Apple; it needs no root,
only IOKit, which ctypes reaches with nothing installed.

MotionSensor(callback) calls callback(x, y, z), in g, from its own thread,
about 100 times a second. available() says whether this Mac has one.
"""
import ctypes
import ctypes.util
import platform
import struct
import threading

_lib = {}


def _load():
    if _lib:
        return _lib
    iokit = ctypes.CDLL(ctypes.util.find_library("IOKit"))
    cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
    vp, u32, i32 = ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int32
    cf.CFStringCreateWithCString.restype = vp
    cf.CFStringCreateWithCString.argtypes = [vp, ctypes.c_char_p, u32]
    cf.CFNumberCreate.restype = vp
    cf.CFNumberCreate.argtypes = [vp, ctypes.c_int, vp]
    cf.CFDictionaryCreateMutable.restype = vp
    cf.CFDictionaryCreateMutable.argtypes = [vp, ctypes.c_long, vp, vp]
    cf.CFDictionarySetValue.argtypes = [vp, vp, vp]
    cf.CFRunLoopGetCurrent.restype = vp
    cf.CFRunLoopRunInMode.restype = i32
    cf.CFRunLoopRunInMode.argtypes = [vp, ctypes.c_double, ctypes.c_bool]
    cf.CFSetGetCount.restype = ctypes.c_long
    cf.CFSetGetCount.argtypes = [vp]
    cf.CFSetGetValues.argtypes = [vp, vp]
    iokit.IOServiceMatching.restype = vp
    iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]
    iokit.IOServiceGetMatchingServices.restype = i32
    iokit.IOServiceGetMatchingServices.argtypes = [u32, vp, ctypes.POINTER(u32)]
    iokit.IOIteratorNext.restype = u32
    iokit.IOIteratorNext.argtypes = [u32]
    iokit.IOObjectRelease.argtypes = [u32]
    iokit.IORegistryEntrySetCFProperty.restype = i32
    iokit.IORegistryEntryCreateCFProperty.restype = vp
    iokit.IORegistryEntryCreateCFProperty.argtypes = [u32, vp, vp, u32]
    iokit.IORegistryEntryGetRegistryEntryID.restype = i32
    iokit.IORegistryEntryGetRegistryEntryID.argtypes = [u32, ctypes.POINTER(ctypes.c_uint64)]
    cf.CFNumberGetValue.restype = ctypes.c_bool
    cf.CFNumberGetValue.argtypes = [vp, ctypes.c_int, vp]
    cf.CFRelease.argtypes = [vp]
    iokit.IORegistryEntrySetCFProperty.argtypes = [u32, vp, vp]
    iokit.IOHIDManagerCreate.restype = vp
    iokit.IOHIDManagerCreate.argtypes = [vp, u32]
    iokit.IOHIDManagerSetDeviceMatching.argtypes = [vp, vp]
    iokit.IOHIDManagerOpen.restype = i32
    iokit.IOHIDManagerOpen.argtypes = [vp, u32]
    iokit.IOHIDManagerCopyDevices.restype = vp
    iokit.IOHIDManagerCopyDevices.argtypes = [vp]
    iokit.IOHIDDeviceOpen.restype = i32
    iokit.IOHIDDeviceOpen.argtypes = [vp, u32]
    iokit.IOHIDDeviceScheduleWithRunLoop.argtypes = [vp, vp, vp]
    cb = ctypes.CFUNCTYPE(None, vp, i32, vp, u32, u32,
                          ctypes.POINTER(ctypes.c_uint8), ctypes.c_long)
    iokit.IOHIDDeviceRegisterInputReportCallback.argtypes = [vp, vp, ctypes.c_long, cb, vp]
    _lib.update(iokit=iokit, cf=cf, cb=cb,
                mode=ctypes.c_void_p.in_dll(cf, "kCFRunLoopDefaultMode"),
                keycb=ctypes.addressof(ctypes.c_char.in_dll(cf, "kCFTypeDictionaryKeyCallBacks")),
                valcb=ctypes.addressof(ctypes.c_char.in_dll(cf, "kCFTypeDictionaryValueCallBacks")))
    return _lib


def _str(t):
    return _load()["cf"].CFStringCreateWithCString(None, t.encode(), 0x08000100)


def _num(v):
    x = ctypes.c_int32(v)
    return _load()["cf"].CFNumberCreate(None, 3, ctypes.byref(x))  # SInt32


_PROPS = ("SensorPropertyReportingState", "SensorPropertyPowerState", "ReportInterval")


def _get_int(svc, key):
    lib = _load()
    ref = lib["iokit"].IORegistryEntryCreateCFProperty(svc, _str(key), None, 0)
    if not ref:
        return None
    v = ctypes.c_int64()
    ok = lib["cf"].CFNumberGetValue(ref, 4, ctypes.byref(v))  # SInt64
    lib["cf"].CFRelease(ref)
    return v.value if ok else None


def _set_reporting(values=None):
    """Sets the sensor drivers streaming (values None) or back to values,
    {entry id: {property: value}}; returns what they were before."""
    lib = _load()
    iokit = lib["iokit"]
    it = ctypes.c_uint32()
    before = {}
    if iokit.IOServiceGetMatchingServices(0, iokit.IOServiceMatching(b"AppleSPUHIDDriver"),
                                          ctypes.byref(it)):
        return before
    while True:
        svc = iokit.IOIteratorNext(it.value)
        if not svc:
            break
        eid = ctypes.c_uint64()
        iokit.IORegistryEntryGetRegistryEntryID(svc, ctypes.byref(eid))
        before[eid.value] = {k: _get_int(svc, k) for k in _PROPS}
        want = (dict(zip(_PROPS, (1, 1, 10000))) if values is None
                else values.get(eid.value, {}))
        for k, v in want.items():
            if v is not None:
                iokit.IORegistryEntrySetCFProperty(svc, _str(k), _num(v))
        iokit.IOObjectRelease(svc)
    iokit.IOObjectRelease(it.value)
    return before


def _devices():
    lib = _load()
    iokit, cf = lib["iokit"], lib["cf"]
    m = iokit.IOHIDManagerCreate(None, 0)
    d = cf.CFDictionaryCreateMutable(None, 0, lib["keycb"], lib["valcb"])
    cf.CFDictionarySetValue(d, _str("PrimaryUsagePage"), _num(0xFF00))
    cf.CFDictionarySetValue(d, _str("PrimaryUsage"), _num(3))
    iokit.IOHIDManagerSetDeviceMatching(m, d)
    if iokit.IOHIDManagerOpen(m, 0):
        return m, []
    devs = iokit.IOHIDManagerCopyDevices(m)
    n = cf.CFSetGetCount(devs) if devs else 0
    arr = (ctypes.c_void_p * n)()
    if n:
        cf.CFSetGetValues(devs, arr)
    return m, list(arr)


def available():
    if platform.system() != "Darwin":
        return False
    try:
        return bool(_devices()[1])
    except OSError:
        return False


class MotionSensor:
    def __init__(self, callback):
        self.callback = callback
        self.running = True
        self.started = threading.Event()
        self.ok = False
        threading.Thread(target=self._run, daemon=True).start()
        self.started.wait(5)

    def _run(self):
        lib = _load()
        iokit, cf = lib["iokit"], lib["cf"]
        self.saved = _set_reporting()
        self.manager, devs = _devices()
        self.bufs = []

        def report(ctx, result, sender, rtype, rid, data, length):
            if length >= 18:
                x, y, z = struct.unpack_from("<iii", bytes(data[:18]), 6)
                self.callback(x / 65536, y / 65536, z / 65536)
        self.cfunc = lib["cb"](report)  # kept: the run loop calls it
        loop = cf.CFRunLoopGetCurrent()
        for dev in devs:
            if iokit.IOHIDDeviceOpen(dev, 0):
                continue
            buf = (ctypes.c_uint8 * 64)()
            self.bufs.append(buf)
            iokit.IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, self.cfunc, None)
            iokit.IOHIDDeviceScheduleWithRunLoop(dev, loop, lib["mode"])
            self.ok = True
        self.started.set()
        while self.running:
            cf.CFRunLoopRunInMode(lib["mode"], 0.2, False)

    def stop(self):
        self.running = False
        # Back to the drivers' own settings, which other users may rely on.
        try:
            _set_reporting(self.saved)
        except (OSError, AttributeError):
            pass
