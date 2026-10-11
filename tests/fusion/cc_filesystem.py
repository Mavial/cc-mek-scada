"""Fault-injecting ComputerCraft host filesystem, shared with the seven-wide patch tests."""
import copy
import posixpath

class SimulatedPowerLoss(Exception):
    pass


class CCFilesystem:
    """Small faithful subset of the CC filesystem required by the installer."""

    def __init__(self, files: dict[str, bytes], free_space: int = 850_000):
        self.files = copy.deepcopy(files)
        self.dirs = {"/"}
        for name in self.files:
            parent = self.getDir(name)
            while parent != "/":
                self.dirs.add(parent)
                parent = self.getDir(parent)
        self.capacity = sum(map(len, files.values())) + free_space
        self.mutations: list[tuple[str, str]] = []
        self.cut_at: tuple[int, str] | None = None
        self.failure: tuple[str, int, str] | None = None
        self.failure_counts: dict[str, int] = {}
        self.fault_used = False
        self.dead = False
        self.lua = None

    @staticmethod
    def path(path: str) -> str:
        return "/" + posixpath.normpath("/" + path.lstrip("/")).lstrip("/")

    def snapshot(self):
        return copy.deepcopy(self.files), set(self.dirs)

    def resumed(self):
        out = CCFilesystem(self.files)
        out.dirs = set(self.dirs)
        out.capacity = self.capacity
        return out

    def alive(self):
        if self.dead:
            raise SimulatedPowerLoss("Filesystem remains unavailable after power loss")

    def mutate(self, kind, detail, action):
        self.alive()
        number = len(self.mutations) + 1
        occurrence = self.failure_counts.get(kind, 0) + 1
        self.failure_counts[kind] = occurrence
        self.mutations.append((kind, detail))
        if self.cut_at == (number, "before"):
            self.dead = True
            raise SimulatedPowerLoss(f"Power loss before {kind} {detail}")
        if not self.fault_used and self.failure == (kind, occurrence, "before"):
            self.fault_used = True
            raise OSError(f"Injected {kind} failure before {detail}")
        action()
        if self.cut_at == (number, "after"):
            self.dead = True
            raise SimulatedPowerLoss(f"Power loss after {kind} {detail}")
        if not self.fault_used and self.failure == (kind, occurrence, "after"):
            self.fault_used = True
            raise OSError(f"Injected {kind} failure after {detail}")

    def exists(self, path):
        self.alive()
        path = self.path(path)
        return path in self.files or path in self.dirs

    def isDir(self, path):
        self.alive()
        return self.path(path) in self.dirs

    def isReadOnly(self, path):
        self.alive()
        return False

    def getDir(self, path):
        return posixpath.dirname(self.path(path)) or "/"

    def combine(self, first, second):
        return self.path(posixpath.join(first, second))

    def getFreeSpace(self, path):
        self.alive()
        return self.capacity - sum(map(len, self.files.values()))

    def getSize(self, path):
        self.alive()
        path = self.path(path)
        return len(self.files[path]) if path in self.files else 0

    def list(self, path):
        self.alive()
        path = self.path(path)
        prefix = path.rstrip("/") + "/"
        names = {name[len(prefix):].split("/")[0] for name in self.files.keys() | self.dirs
                 if name.startswith(prefix) and name != path}
        return self.lua.table_from(sorted(names))

    def makeDir(self, path):
        self.alive()
        path = self.path(path)
        if path in self.dirs:
            return
        if path in self.files:
            raise OSError("Cannot create directory over a file")

        def action():
            parent = path
            while parent != "/":
                self.dirs.add(parent)
                parent = self.getDir(parent)
        self.mutate("mkdir", path, action)

    def move(self, source, destination):
        self.alive()
        source, destination = self.path(source), self.path(destination)
        if source not in self.files:
            raise OSError(f"Missing move source: {source}")
        if destination in self.files or destination in self.dirs:
            raise OSError(f"Move destination already exists: {destination}")
        if self.getDir(destination) not in self.dirs:
            raise OSError(f"Missing move parent: {destination}")
        self.mutate("move", source + " -> " + destination,
                    lambda: self.files.__setitem__(destination, self.files.pop(source)))

    def delete(self, path):
        self.alive()
        path = self.path(path)
        if path not in self.files and path not in self.dirs:
            return

        def action():
            prefix = path.rstrip("/") + "/"
            self.files = {name: data for name, data in self.files.items()
                          if name != path and not name.startswith(prefix)}
            self.dirs = {name for name in self.dirs
                         if name == "/" or (name != path and not name.startswith(prefix))}
        self.mutate("delete", path, action)

    def open(self, path, mode):
        self.alive()
        path = self.path(path)
        if mode in ("r", "rb"):
            if path not in self.files:
                return None, "No such file"
            original = self.files[path]
            return self.lua.table_from({
                "readAll": lambda: original.decode("latin1"),
                "close": lambda: None,
            })
        if mode not in ("w", "wb"):
            raise AssertionError(f"Unsupported open mode: {mode}")
        if self.getDir(path) not in self.dirs:
            return None, "Missing parent directory"
        self.mutate("open_write", path, lambda: self.files.__setitem__(path, b""))

        def write(data):
            data = data.encode("latin1") if isinstance(data, str) else data
            if len(data) > self.getFreeSpace("/"):
                raise OSError("Out of space")
            self.mutate("write", path,
                        lambda: self.files.__setitem__(path, self.files[path] + data))

        def close():
            self.alive()
        return self.lua.table_from({"write": write, "close": close})
