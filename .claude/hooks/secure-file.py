#!/usr/bin/env python3
"""Bounded file operations that never follow repository-controlled links."""

import ntpath
import os
import secrets
import stat
import sys


MAX_INPUT_BYTES = 2 * 1024 * 1024
MAX_READ_BYTES = 16 * 1024 * 1024
MAX_RELATIVE_LENGTH = 1024
REPARSE_POINT_ATTRIBUTE = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)


class SecureFileError(Exception):
    pass


def _is_reparse(value):
    return bool(getattr(value, "st_file_attributes", 0) & REPARSE_POINT_ATTRIBUTE)


def _reject_redirect(value, label):
    if stat.S_ISLNK(value.st_mode) or _is_reparse(value):
        raise SecureFileError("{} is a symbolic link or reparse point".format(label))


def _parts(relative):
    if not relative or len(relative) > MAX_RELATIVE_LENGTH:
        raise SecureFileError("relative path is empty or too long")
    if "\\" in relative or os.path.isabs(relative) or ntpath.isabs(relative):
        raise SecureFileError("path must be a portable repository-relative path")
    if ntpath.splitdrive(relative)[0]:
        raise SecureFileError("drive-qualified paths are not allowed")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in relative):
        raise SecureFileError("control characters are not allowed in paths")
    result = relative.split("/")
    if any(part in ("", ".", "..") for part in result):
        raise SecureFileError("path contains an empty or traversal component")
    return result


def _root(path):
    absolute = os.path.abspath(path)
    try:
        info = os.lstat(absolute)
    except OSError as exc:
        raise SecureFileError("project root is unavailable: {}".format(exc.__class__.__name__))
    _reject_redirect(info, "project root")
    if not stat.S_ISDIR(info.st_mode):
        raise SecureFileError("project root is not a directory")
    canonical = os.path.realpath(absolute)
    if os.path.normcase(canonical) != os.path.normcase(absolute):
        raise SecureFileError("project root must be canonical")
    return canonical


def _read_stdin():
    data = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise SecureFileError("input exceeds the 2 MiB safety limit")
    return data


def _write_all(descriptor, data):
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise SecureFileError("short write")
        view = view[written:]


def _supports_descriptor_walk():
    return (
        os.name != "nt"
        and os.open in getattr(os, "supports_dir_fd", set())
        and os.mkdir in getattr(os, "supports_dir_fd", set())
        and os.stat in getattr(os, "supports_dir_fd", set())
    )


def _directory_flags():
    return (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )


def _open_parent_descriptor(root, parts, create):
    descriptor = os.open(root, _directory_flags())
    try:
        for part in parts[:-1]:
            try:
                child = os.open(part, _directory_flags(), dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    raise SecureFileError("parent directory does not exist")
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                child = os.open(part, _directory_flags(), dir_fd=descriptor)
            info = os.fstat(child)
            _reject_redirect(info, "parent directory")
            if not stat.S_ISDIR(info.st_mode):
                os.close(child)
                raise SecureFileError("parent component is not a directory")
            os.close(descriptor)
            descriptor = child
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _check_open_file(descriptor):
    info = os.fstat(descriptor)
    _reject_redirect(info, "opened file")
    if not stat.S_ISREG(info.st_mode):
        raise SecureFileError("target is not a regular file")
    if info.st_nlink != 1:
        raise SecureFileError("target has multiple filesystem links")
    return info


def _clear_nonblock(descriptor):
    try:
        import fcntl
        flags = fcntl.fcntl(descriptor, fcntl.F_GETFL)
        if flags & os.O_NONBLOCK:
            fcntl.fcntl(descriptor, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    except (AttributeError, ImportError, OSError):
        pass


def _acquire_write_lock(parent_descriptor):
    import fcntl
    fcntl.flock(parent_descriptor, fcntl.LOCK_EX)
    return (fcntl, parent_descriptor)


def _release_write_lock(lock):
    if lock is None:
        return
    api, descriptor = lock
    api.flock(descriptor, api.LOCK_UN)


def _descriptor_operation(operation, root, parts):
    if operation == "mkdir":
        marker = parts + [".ccgs-directory-marker"]
        parent = _open_parent_descriptor(root, marker, True)
        os.close(parent)
        return b""

    parent = _open_parent_descriptor(root, parts, operation in ("append", "replace"))
    name = parts[-1]
    binary = getattr(os, "O_BINARY", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    cloexec = getattr(os, "O_CLOEXEC", 0)
    nonblock = getattr(os, "O_NONBLOCK", 0)
    lock = None
    try:
        if operation == "read":
            descriptor = os.open(name, os.O_RDONLY | binary | nofollow | cloexec | nonblock, dir_fd=parent)
            try:
                info = _check_open_file(descriptor)
                _clear_nonblock(descriptor)
                if info.st_size > MAX_READ_BYTES:
                    raise SecureFileError("file exceeds the 16 MiB safety limit")
                chunks = []
                total = 0
                while True:
                    chunk = os.read(descriptor, min(65536, MAX_READ_BYTES + 1 - total))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    total += len(chunk)
                    if total > MAX_READ_BYTES:
                        raise SecureFileError("file exceeds the 16 MiB safety limit")
                return b"".join(chunks)
            finally:
                os.close(descriptor)

        data = _read_stdin()
        lock = _acquire_write_lock(parent)
        if operation == "append":
            existing = b""
            try:
                descriptor = os.open(name, os.O_RDONLY | binary | nofollow | cloexec | nonblock, dir_fd=parent)
            except FileNotFoundError:
                descriptor = None
            if descriptor is not None:
                try:
                    info = _check_open_file(descriptor)
                    _clear_nonblock(descriptor)
                    if info.st_size > MAX_READ_BYTES:
                        raise SecureFileError("file exceeds the 16 MiB safety limit")
                    chunks = []
                    total = 0
                    while True:
                        chunk = os.read(descriptor, min(65536, MAX_READ_BYTES + 1 - total))
                        if not chunk:
                            break
                        chunks.append(chunk)
                        total += len(chunk)
                        if total > MAX_READ_BYTES:
                            raise SecureFileError("file exceeds the 16 MiB safety limit")
                    existing = b"".join(chunks)
                finally:
                    os.close(descriptor)
            if len(existing) + len(data) > MAX_READ_BYTES:
                raise SecureFileError("appended file would exceed the 16 MiB safety limit")
            data = existing + data
            operation = "replace"

        if operation == "replace":
            try:
                existing = os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                existing = None
            if existing is not None:
                _reject_redirect(existing, "target")
                if not stat.S_ISREG(existing.st_mode) or existing.st_nlink != 1:
                    raise SecureFileError("existing target is not a singly-linked regular file")
            temp_name = ".ccgs-write-{}".format(secrets.token_hex(12))
            descriptor = os.open(
                temp_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | binary | nofollow | cloexec,
                0o600,
                dir_fd=parent,
            )
            try:
                try:
                    _check_open_file(descriptor)
                    _write_all(descriptor, data)
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
                os.replace(temp_name, name, src_dir_fd=parent, dst_dir_fd=parent)
            except Exception:
                try:
                    os.unlink(temp_name, dir_fd=parent)
                except OSError:
                    pass
                raise
            return b""
        raise SecureFileError("unsupported operation")
    finally:
        _release_write_lock(lock)
        os.close(parent)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("append", "replace", "read", "mkdir"):
        sys.stderr.write("secure-file: expected OPERATION ROOT RELATIVE_PATH\n")
        return 2
    operation, root_arg, relative = sys.argv[1:]
    try:
        root = _root(root_arg)
        parts = _parts(relative)
        if not _supports_descriptor_walk():
            raise SecureFileError(
                "operation requires handle-relative filesystem traversal; "
                "this platform is fail-closed"
            )
        output = _descriptor_operation(operation, root, parts)
    except (OSError, SecureFileError) as exc:
        sys.stderr.write("secure-file: {}\n".format(exc))
        return 1
    if output:
        sys.stdout.buffer.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
