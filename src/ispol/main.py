import isapi.files
import isapi.notebooks
import signal
import sys
import yaml
import json
import time
import requests
import re

overrides = set(sys.argv[2:])
RE_STARNUM = re.compile(r'[*]([.]?[0-9])')


def escape_points(txt : str) -> str:
    return RE_STARNUM.sub(r'* \1', txt)


def fprint(what, **kvargs):
    print(what, flush=True, **kvargs)


def process_file(course : str, notebooks : isapi.notebooks.Connection,
                 files : isapi.files.Connection,
                 filemeta : isapi.files.FileMeta, conf : dict,
                 upstream : str, forced : bool = False) -> None:
    fprint(f"Processing {filemeta.ispath}…")
    qid = conf["id"]
    attempts = conf.get("attempts")
    note = conf["notebook"]["short"]
    note_name = conf["notebook"]["name"]
    notebook = notebooks.get_or_create(shortcut=note, name=note_name,
                          visible=conf["notebook"].get("visible", False),
                          statistics=conf["notebook"].get("statistics", False))
    is_entry = notebook.get(filemeta.author, isapi.notebooks.Entry(""))
    entry = yaml.safe_load(is_entry.text) or {}
    timestamp = time.strftime("%Y-%m-%d %H:%M")

    base_entry = {"time": timestamp, "filename": filemeta.shortname}
    data = files.get_file(filemeta).data.decode("utf8")
    total_points = None
    if "attempts" not in entry:
        entry["attempts"] = [base_entry]
    else:
        entry["attempts"].insert(0, base_entry)
    if not forced and attempts is not None and len(entry.get("attempts", [])) > attempts:
        entry["attempts"][0]["error"] = "Too many attempts"
    else:
        req = requests.post(upstream, {"kod": course, "id": qid, "odp": data,
                                       "uco": filemeta.author,
                                       "mode": "json"})
        assert req.status_code == 200
        response = json.loads(req.text)
        if "comment" in response:
            response["comment"] = response["comment"].rstrip()
        total_points = sum(p["points"] for p in response["points"])
        entry["total_points"] = f"*{total_points}"
        entry["attempts"][0].update(response)

    is_entry.text = yaml.dump(entry, default_flow_style=False)
    notebooks.store(note, filemeta.author, is_entry)
    fprint(f"done, {total_points} points")


def poll():
    files = isapi.files.Connection()
    with open(sys.argv[1]) as conf_file:
        config = yaml.safe_load(conf_file)
    for course, dirs in config["courses"].items():
        notebooks = isapi.notebooks.Connection(course=course)
        for d in dirs:
            paths = d.get("paths", [])
            if "path" in d:
                paths.append(d["path"])
            for path in paths:
                try:
                    entries = files.list_directory(path).entries
                except isapi.files.FileAPIException as ex:
                    fprint(f"ERROR while lising {path}: {ex}")
                    continue

                for f in entries:
                    forced = f.ispath in overrides
                    if not forced and len(overrides):
                        continue
                    if not forced and f.read:
                        fprint(f"Skipping read {f.ispath}")
                        continue
                    process_file(course, notebooks, files, f, d,
                                 config["upstream"], forced)


def main():
    if len(sys.argv) < 2:
        fprint(f"Usage {sys.argv[0]} config.yml")
        sys.exit(1)
    with open(sys.argv[1]) as conf_file:
        config = yaml.safe_load(conf_file)
    fprint(config)
    interval = float(config["interval"])

    stop_signal = False

    def poller():
        while True:
            start = time.perf_counter()
            poll()
            sleep_for = int((max(1, interval - (time.perf_counter() - start))))
            for _ in range(sleep_for):
                if stop_signal:
                    return
                time.sleep(1)
            if stop_signal:
                return

    def stop(sig, stack):
        nonlocal stop_signal
        stop_signal = True
        fprint(f"cancellation pending (SIG={sig})… ")

    signal.signal(signal.SIGTERM, stop)

    if len(sys.argv) > 2:
        stop_signal = True
        fprint("Will only handle forced files")
    poller()
    fprint("exiting…")


if __name__ == "__main__":
    main()

# vim: colorcolumn=80 expandtab sw=4 ts=4