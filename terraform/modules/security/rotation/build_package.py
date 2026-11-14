"""Build a reproducible rotation ZIP from hash-locked universal wheels."""

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import ssl
import subprocess
import sys
import tempfile
import zipfile


RDS_CA_SHA256 = "b1711d12bae51838581281e23b6cb97b1074016873b4dafc80ed14002462dd77"


def wheel_files(wheel):
    """Keep importable wheel contents; console entry points are unused by Lambda."""
    if not wheel.name.endswith("-none-any.whl"):
        raise ValueError(f"The runtime lock must contain universal wheels: {wheel.name}")
    with zipfile.ZipFile(wheel) as archive:
        for entry in archive.infolist():
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename:
                raise ValueError("Wheel contains an unsafe path")
            if entry.is_dir() or "__pycache__" in path.parts or path.suffix == ".pyc":
                continue
            if path.parts[0].endswith(".data"):
                # Wheels may carry CLI scripts with installer-generated shebangs.
                if len(path.parts) > 2 and path.parts[1] in {"purelib", "platlib"}:
                    path = PurePosixPath(*path.parts[2:])
                else:
                    continue
            yield path.as_posix(), archive.read(entry)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ca-bundle", type=Path, help="Custom PostgreSQL CA bundle instead of the AWS us-east-1 RDS bundle")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    bundle = (args.ca_bundle or source / "us-east-1-rds-ca.pem").read_bytes()
    if not args.ca_bundle and hashlib.sha256(bundle).hexdigest() != RDS_CA_SHA256:
        raise ValueError("The vendored RDS CA bundle does not match its reviewed SHA-256")
    ssl.create_default_context(cadata=bundle.decode("ascii"))

    build = source.parent / ".build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rotation-package-") as temporary:
        wheelhouse = Path(temporary)
        subprocess.run(
            [
                sys.executable, "-m", "pip", "--isolated", "download", "--disable-pip-version-check",
                "--retries", "0", "--timeout", "15", "--index-url", "https://pypi.org/simple",
                "--only-binary=:all:", "--require-hashes", "--dest", str(wheelhouse),
                "-r", str(source / "requirements.txt"),
            ],
            check=True,
        )
        contents = {"handler.py": (source / "handler.py").read_bytes(), "postgres-ca.pem": bundle}
        for wheel in sorted(wheelhouse.glob("*.whl")):
            for name, data in wheel_files(wheel):
                if name in contents:
                    raise ValueError(f"Duplicate runtime package path: {name}")
                contents[name] = data
        # Stored entries avoid differences between host zlib versions. The package
        # remains below Lambda's 50 MiB ZIP upload limit with this dependency lock.
        destination = build / "rotation.zip"
        candidate = wheelhouse / "rotation.zip"
        with zipfile.ZipFile(candidate, "w", compression=zipfile.ZIP_STORED) as archive:
            for name, data in sorted(contents.items()):
                entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                archive.writestr(entry, data)
        if candidate.stat().st_size >= 50 * 1024 * 1024:
            raise ValueError("Rotation ZIP exceeds Lambda's 50 MiB upload limit")
        # Publish only a complete successful build; keep the previous ZIP on error.
        with tempfile.NamedTemporaryFile(dir=build, prefix="rotation-", suffix=".zip", delete=False) as output:
            staged = Path(output.name)
            try:
                output.write(candidate.read_bytes())
                output.close()
                staged.replace(destination)
            finally:
                staged.unlink(missing_ok=True)
    print(destination)
    return 0


if __name__ == "__main__":
    sys.exit(main())
