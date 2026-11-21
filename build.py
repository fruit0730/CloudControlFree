import os
import re
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
INCLUDE_DIRS = ["META-INF", "config", "webroot"]
INCLUDE_FILES = ["module.prop", "customize.sh", "post-fs-data.sh", "service.sh",
                 "action.sh", "uninstall.sh", "qyk.sh"]


def module_version():
    with open(os.path.join(ROOT, "module.prop"), encoding="utf-8") as f:
        m = re.search(r"^version=(.+)$", f.read(), re.M)
    return m.group(1).strip() if m else "dev"


def main():
    name = f"qyk_CloudControlFree_{module_version()}.zip"
    out = os.path.join(ROOT, "dist", name)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in INCLUDE_FILES:
            z.write(os.path.join(ROOT, f), f)
        for d in INCLUDE_DIRS:
            for root, _, files in os.walk(os.path.join(ROOT, d)):
                for f in sorted(files):
                    p = os.path.join(root, f)
                    z.write(p, os.path.relpath(p, ROOT).replace(os.sep, "/"))
    print(f"{out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    main()
