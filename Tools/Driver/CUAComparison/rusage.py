"""proc_pid_rusage (RUSAGE_INFO_V6) through ctypes: CPU in ns, instructions, cycles, energy and footprint."""
import ctypes, subprocess

_FIELDS = ("uuid user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size "
           "phys_footprint proc_start_abstime proc_exit_abstime child_user_time child_system_time "
           "child_pkg_idle_wkups child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread "
           "diskio_byteswritten qos_default qos_maintenance qos_background qos_utility qos_legacy "
           "qos_user_initiated qos_user_interactive billed_system_time serviced_system_time logical_writes "
           "lifetime_max_phys_footprint instructions cycles billed_energy serviced_energy "
           "interval_max_phys_footprint runnable_time flags user_ptime system_ptime pinstructions pcycles "
           "energy_nj penergy_nj").split()

class _V6(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(f, ctypes.c_uint64) for f in _FIELDS[1:]] \
               + [("rest", ctypes.c_uint64 * 20)]

_lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
_info = ctypes.CDLL("/usr/lib/libSystem.dylib")

class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
_tb = _Timebase(); _info.mach_timebase_info(ctypes.byref(_tb))
TICK_NS = _tb.numer / _tb.denom

def sample(pid):
    """A dict of counters, CPU in ns; None when the kernel refuses (another user's process)."""
    buf = _V6()
    if _lib.proc_pid_rusage(int(pid), 6, ctypes.byref(buf)) != 0:
        return None
    return {"cpu_ns": (buf.user_time + buf.system_time) * TICK_NS,
            "instructions": buf.instructions, "cycles": buf.cycles,
            "energy_nj": buf.energy_nj, "billed_energy": buf.billed_energy,
            "footprint": buf.phys_footprint, "peak_footprint": buf.lifetime_max_phys_footprint,
            "wakeups": buf.pkg_idle_wkups + buf.interrupt_wkups}

class _Point(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]

_quartz = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
_quartz.CGEventCreate.restype = ctypes.c_void_p
_quartz.CGEventCreate.argtypes = [ctypes.c_void_p]
_quartz.CGEventGetLocation.restype = _Point
_quartz.CGEventGetLocation.argtypes = [ctypes.c_void_p]
_cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
_cf.CFRelease.argtypes = [ctypes.c_void_p]

def cursor():
    """The physical cursor in global points, read in process (no event is posted)."""
    event = _quartz.CGEventCreate(None)
    point = _quartz.CGEventGetLocation(event)
    _cf.CFRelease(event)
    return (point.x, point.y)

def ps_cpu_ns(pid):
    """CPU time from ps, 10 ms resolution, for processes proc_pid_rusage cannot read."""
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out: return None
    parts = out.replace("-", ":").split(":")
    seconds = 0.0
    for p in parts: seconds = seconds * 60 + float(p)
    return seconds * 1e9

if __name__ == "__main__":
    import os
    me = sample(os.getpid()); assert me and me["cpu_ns"] > 0 and me["footprint"] > 0, me
    ws = int(subprocess.run(["pgrep", "-x", "WindowServer"], capture_output=True, text=True).stdout.split()[0])
    assert len(cursor()) == 2
    print("self ok", round(me["cpu_ns"]/1e6,1), "ms cpu", me["footprint"]>>20, "MB; WindowServer rusage:",
          sample(ws) is not None, "ps:", ps_cpu_ns(ws))
