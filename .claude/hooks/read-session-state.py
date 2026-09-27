#!/usr/bin/env python3
"""Read active.md through one validated file descriptor."""

import os
import stat
import sys


PARTS = ("production", "session-state", "active.md")
MAX_BYTES = 1024 * 1024
REPARSE_POINT_ATTRIBUTE = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)


class StateReadError(Exception):
    pass


def _is_reparse_point(value):
    """Return whether a Windows stat result redirects filesystem traversal."""
    return bool(getattr(value, "st_file_attributes", 0) & REPARSE_POINT_ATTRIBUTE)


def _mtime_ns(value):
    return getattr(value, "st_mtime_ns", int(value.st_mtime * 1000000000))


def _ctime_ns(value):
    return getattr(value, "st_ctime_ns", int(value.st_ctime * 1000000000))


def _identity(value):
    identity = (value.st_dev, value.st_ino)
    if value.st_ino == 0:
        identity += (value.st_size, _mtime_ns(value), _ctime_ns(value))
    return identity


def _fingerprint(value):
    return (
        _identity(value),
        stat.S_IFMT(value.st_mode),
        value.st_nlink,
        value.st_size,
        _mtime_ns(value),
        _ctime_ns(value),
    )


def _inspect_path(root):
    current = root
    snapshots = []
    for index, part in enumerate(PARTS):
        current = os.path.join(current, part)
        try:
            item = os.lstat(current)
        except OSError as exc:
            raise StateReadError("checkpoint path is unavailable: {}".format(exc.__class__.__name__))
        if stat.S_ISLNK(item.st_mode) or _is_reparse_point(item):
            raise StateReadError("checkpoint path contains a symbolic link or reparse point")
        if index < len(PARTS) - 1 and not stat.S_ISDIR(item.st_mode):
            raise StateReadError("checkpoint parent is not a directory")
        snapshots.append(item)
    return current, snapshots


def _read_validated(root_arg):
    root = os.path.realpath(os.path.abspath(root_arg))
    if not os.path.isdir(root):
        raise StateReadError("project root is unavailable")

    target, before_path = _inspect_path(root)
    before_target = before_path[-1]
    if not stat.S_ISREG(before_target.st_mode):
        raise StateReadError("checkpoint is not a regular file")
    if before_target.st_nlink != 1:
        raise StateReadError("checkpoint has multiple filesystem links")

    flags = os.O_RDONLY
    flags |= getattr(os, "O_BINARY", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)

    try:
        descriptor = os.open(target, flags)
    except OSError as exc:
        raise StateReadError("checkpoint could not be opened safely: {}".format(exc.__class__.__name__))

    try:
        opened_before = os.fstat(descriptor)
        _, after_open_path = _inspect_path(root)
        after_open_target = after_open_path[-1]

        if not stat.S_ISREG(opened_before.st_mode):
            raise StateReadError("opened checkpoint is not a regular file")
        if opened_before.st_nlink != 1:
            raise StateReadError("opened checkpoint has multiple filesystem links")
        if _fingerprint(before_target) != _fingerprint(opened_before):
            raise StateReadError("checkpoint changed before it was opened")
        if _identity(opened_before) != _identity(after_open_target):
            raise StateReadError("checkpoint changed while it was opened")
        if opened_before.st_size > MAX_BYTES:
            raise StateReadError("checkpoint exceeds the 1 MiB safety limit")

        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, MAX_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_BYTES:
                raise StateReadError("checkpoint exceeds the 1 MiB safety limit")

        opened_after = os.fstat(descriptor)
        _, after_read_path = _inspect_path(root)
        after_read_target = after_read_path[-1]
        if _identity(opened_after) != _identity(after_read_target):
            raise StateReadError("checkpoint path changed during the read")
        if _fingerprint(opened_before) != _fingerprint(opened_after):
            raise StateReadError("checkpoint content changed during the read")

        data = b"".join(chunks)
        if b"\x00" in data:
            raise StateReadError("checkpoint contains a NUL byte")
        return data
    finally:
        os.close(descriptor)


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("session-state security: expected one project root\n")
        return 2
    try:
        data = _read_validated(sys.argv[1])
    except StateReadError as exc:
        sys.stderr.write("session-state security: {}\n".format(exc))
        return 1
    sys.stdout.buffer.write(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
